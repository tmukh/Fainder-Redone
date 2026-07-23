#!/usr/bin/env python3
"""OOD dispatch validation analyser for c1024_56gb.

Reads bench.db, finds the actually-best build per thread count at
the new OOD dataset, and compares to the dispatch policy's prediction.

Outcomes:
  - 6/6 within 5% of regime-best → dispatch generalises to sparser-cluster
    regime. Claim 2 robust to K-axis variation.
  - <6/6 → 4th regime cell. Print the gap and the build the policy should
    have picked.

Usage:
    scripts/analyse_ood_dispatch.py [--dataset c1024_56gb] [--n-hists 5017619]
"""
from __future__ import annotations
import argparse
import sqlite3
import statistics
import struct
from pathlib import Path
from fainder.execution.dispatch import select_engine, EngineConfig

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "logs" / "bench.db"

# Build → label-suffix mapping for the OOD sweep (matches
# run_ood_dispatch_validation.sh).
OOD_BUILDS = {
    "ood_default":      {"features": "",                                                              "env": {}},
    "ood_bestofsuite":  {"features": "pooled f16 simd pin-cores cluster-prefetch mimalloc",           "env": {}},
    "ood_packed_ids":   {"features": "packed-ids",                                                    "env": {}},
    "ood_qbatch_K64":   {"features": "query-batch",                                                   "env": {"FAINDER_QUERY_BATCH": "64"}},
    "ood_qbatch_K128":  {"features": "query-batch",                                                   "env": {"FAINDER_QUERY_BATCH": "128"}},
}


def cfg_matches(cfg: EngineConfig, build_features: str, build_env: dict) -> bool:
    cfg_feats = set(cfg.features.split()) if cfg.features else set()
    blt_feats = set(build_features.split()) if build_features else set()
    if cfg_feats != blt_feats:
        return False
    if cfg.env.get("FAINDER_QUERY_BATCH") != build_env.get("FAINDER_QUERY_BATCH"):
        return False
    return True


def med(con: sqlite3.Connection, label: str, build: str, t: int) -> float | None:
    rows = list(con.execute(
        "SELECT wall_s FROM runs WHERE label=? AND build=? AND threads=?",
        (label, build, t),
    ))
    if not rows:
        return None
    return statistics.median(r[0] for r in rows)


def read_n_clusters_from_fidx(fidx_path: Path) -> int | None:
    """Best-effort n_clusters extraction from the fidx directory layout.

    The fidx is a directory of `bins_<i>.npy` + `pctl_<i>.npy` files, one
    pair per cluster; count `bins_*.npy` to recover n_clusters.
    """
    if not fidx_path.is_dir():
        return None
    bins_files = list(fidx_path.glob("bins_*.npy"))
    if bins_files:
        return len(bins_files)
    return None


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--dataset", default="c1024_56gb")
    p.add_argument("--n-hists", type=int, default=5_017_619)
    p.add_argument("--n-clusters", type=int, default=0,
                   help="Override; 0 = auto-detect from fidx")
    args = p.parse_args()

    if args.n_clusters == 0:
        fidx = Path(f"/local-data/abumukh/data/gittables/{args.dataset}/indices/best_config_rebinning.fidx")
        nc = read_n_clusters_from_fidx(fidx)
        if nc is None:
            print(f"WARNING: could not auto-detect n_clusters from {fidx}; assuming 750 (typical K=1024 collapse)")
            args.n_clusters = 750
        else:
            args.n_clusters = nc
            print(f"Detected n_clusters = {nc} from fidx layout")

    con = sqlite3.connect(DB)
    label_prefix = f"ood_{args.dataset}_"

    print()
    print(f"{'t':>4} | {'recommended':>30} | {'rec wall':>9} | {'best build':>22} | {'best wall':>9} | {'gap':>7}")
    print("-" * 96)

    n_total = 0
    n_correct = 0
    n_near = 0
    failures = []

    for t in [1, 8, 16, 32, 64, 96]:
        cfg = select_engine(
            n_clusters=args.n_clusters,
            n_hists=args.n_hists,
            n_threads=t,
        )

        # Find actual best build at this t.
        candidates: list[tuple[str, float]] = []
        for build_name, build_info in OOD_BUILDS.items():
            label_suffix = build_name.removeprefix("ood_")
            label = f"{label_prefix}{label_suffix}"
            w = med(con, label, build_name, t)
            if w is not None:
                candidates.append((build_name, w))

        if not candidates:
            print(f"{t:>4} | (no data)")
            continue
        candidates.sort(key=lambda x: x[1])
        best_name, best_wall = candidates[0]

        # Find what the policy picked.
        picked_wall: float | None = None
        picked_name: str | None = None
        for build_name, build_info in OOD_BUILDS.items():
            if cfg_matches(cfg, build_info["features"], build_info["env"]):
                label_suffix = build_name.removeprefix("ood_")
                label = f"{label_prefix}{label_suffix}"
                picked_wall = med(con, label, build_name, t)
                picked_name = build_name
                break

        rec_str = cfg.features or "default"
        if cfg.env.get("FAINDER_QUERY_BATCH"):
            rec_str += f" K={cfg.env['FAINDER_QUERY_BATCH']}"

        if picked_wall is None:
            print(f"{t:>4} | {rec_str[:30]:>30} | {'(no data)':>9} | {best_name:>22} | {best_wall:>9.2f} | {'-':>7}")
            continue

        gap_pct = (picked_wall - best_wall) / best_wall * 100
        n_total += 1
        if picked_name == best_name:
            n_correct += 1
        if gap_pct <= 5.0:
            n_near += 1
        else:
            failures.append((t, picked_name, picked_wall, best_name, best_wall, gap_pct))

        print(f"{t:>4} | {rec_str[:30]:>30} | {picked_wall:>9.2f} | {best_name:>22} | {best_wall:>9.2f} | {gap_pct:>+6.1f}%")

    print("-" * 96)
    print(f"\nDispatch picks regime-best:           {n_correct}/{n_total} cells")
    print(f"Dispatch within 5% of regime-best:    {n_near}/{n_total} cells")

    if failures:
        print("\n--- Falsification points (>5% gap) ---")
        for t, picked, pw, best, bw, gp in failures:
            print(f"  t={t}: policy picked '{picked}' ({pw:.2f}s) but '{best}' is {gp:+.1f}% better ({bw:.2f}s)")
        print("\nThis is a 4th regime cell. The dispatch policy needs n_clusters as a real axis.")
        return 1

    print("\nDispatch generalises to the sparser-cluster regime. Claim 2 robust to K-axis variation.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
