#!/usr/bin/env python3
"""Empirical validation of the dispatch-on-regime policy in fainder.execution.dispatch.

For each (dataset, n_threads) cell we have measured medians for, ask the policy
which engine it would pick, then compare against the measured regime-best.
A "correct" pick is within ε of the regime-best wall_s.

Usage:
    scripts/validate_dispatch.py
"""
from __future__ import annotations
import sqlite3
import statistics
from pathlib import Path
from fainder.execution.dispatch import select_engine, EngineConfig

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "logs" / "bench.db"

# Hardcoded n_clusters / n_hists for the 3 datasets in the campaign.
# Source: dataset metadata; rough order of magnitude is what matters.
DATASETS = {
    "10gb": {"n_clusters": 129, "n_hists": 130_000},
    "30gb": {"n_clusters": 184, "n_hists": 410_000},
    "56gb": {"n_clusters": 191, "n_hists": 770_000},
}

# Map each candidate-build name (as stored in bench.db) to a description
# of what the dispatch policy would call it.
BUILDS = {
    "default":           {"features": "",                                                              "env": {}},
    "packed_ids":        {"features": "packed-ids",                                                    "env": {}},
    "bestofsuite":       {"features": "pooled f16 simd pin-cores cluster-prefetch mimalloc",           "env": {}},
    "query_batch":       {"features": "query-batch",                                                   "env": {"FAINDER_QUERY_BATCH": "64"}},
    "query_batch_k128":  {"features": "query-batch",                                                   "env": {"FAINDER_QUERY_BATCH": "128"}},
    "query_batch_k256":  {"features": "query-batch",                                                   "env": {"FAINDER_QUERY_BATCH": "256"}},
}


def cfg_matches(cfg: EngineConfig, build_features: str, build_env: dict) -> bool:
    """Return True if the policy-recommended cfg equals the build's features+env.

    Since features may be ordered differently, compare as sorted sets.
    K is checked against the env var.
    """
    cfg_feats = set(cfg.features.split()) if cfg.features else set()
    blt_feats = set(build_features.split()) if build_features else set()
    if cfg_feats != blt_feats:
        return False
    # Compare relevant env vars (we only care about FAINDER_QUERY_BATCH for
    # query-batch builds; ignore others).
    cfg_qb = cfg.env.get("FAINDER_QUERY_BATCH")
    blt_qb = build_env.get("FAINDER_QUERY_BATCH")
    if cfg_qb != blt_qb:
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


def main() -> int:
    con = sqlite3.connect(DB)
    print(f"{'dataset':>8} {'t':>4} | {'recommended':>30} | {'rec wall':>9} | {'best build':>20} | {'best wall':>9} | {'gap':>6}")
    print("-" * 110)

    n_correct = 0
    n_total = 0
    n_near = 0  # within 5% of regime-best

    for size in ["10gb", "30gb", "56gb"]:
        for t in [1, 8, 16, 32, 64, 96]:
            cfg = select_engine(
                n_clusters=DATASETS[size]["n_clusters"],
                n_hists=DATASETS[size]["n_hists"],
                n_threads=t,
            )

            # Find the actual regime-best from bench.db.
            candidates: list[tuple[str, float]] = []
            for build_name, build_info in BUILDS.items():
                # Map build_name to its label suffix in bench.db.
                label_suffix = {
                    "default":          "default",
                    "packed_ids":       "packed_ids",
                    "bestofsuite":      "bestofsuite",
                    "query_batch":      "query_batch",
                    "query_batch_k128": "query_batch_k128",
                    "query_batch_k256": "query_batch_k256",
                }[build_name]
                label = f"main_{size}_{label_suffix}_supp"
                w = med(con, label, build_name, t)
                if w is not None:
                    candidates.append((build_name, w))
            if not candidates:
                continue
            candidates.sort(key=lambda x: x[1])
            regime_best_name, regime_best_wall = candidates[0]

            # Find the build the policy picked, if it exists in our DB.
            picked_wall: float | None = None
            picked_build_name: str | None = None
            for build_name, build_info in BUILDS.items():
                if cfg_matches(cfg, build_info["features"], build_info["env"]):
                    label_suffix = {
                        "default":          "default",
                        "packed_ids":       "packed_ids",
                        "bestofsuite":      "bestofsuite",
                        "query_batch":      "query_batch",
                        "query_batch_k128": "query_batch_k128",
                        "query_batch_k256": "query_batch_k256",
                    }[build_name]
                    label = f"main_{size}_{label_suffix}_supp"
                    picked_wall = med(con, label, build_name, t)
                    picked_build_name = build_name
                    break

            if picked_wall is None:
                rec_str = f"{cfg.features or 'default'}"
                if cfg.env.get("FAINDER_QUERY_BATCH"):
                    rec_str += f" K={cfg.env['FAINDER_QUERY_BATCH']}"
                print(f"{size:>8} {t:>4} | {rec_str[:30]:>30} | {'(no data)':>9} | {regime_best_name:>20} | {regime_best_wall:>9.2f} | {'-':>6}")
                continue

            gap_pct = (picked_wall - regime_best_wall) / regime_best_wall * 100
            n_total += 1
            if picked_build_name == regime_best_name:
                n_correct += 1
            if gap_pct <= 5.0:
                n_near += 1
            rec_str = f"{cfg.features or 'default'}"
            if cfg.env.get("FAINDER_QUERY_BATCH"):
                rec_str += f" K={cfg.env['FAINDER_QUERY_BATCH']}"
            print(f"{size:>8} {t:>4} | {rec_str[:30]:>30} | {picked_wall:>9.2f} | {regime_best_name:>20} | {regime_best_wall:>9.2f} | {gap_pct:>+5.1f}%")

    print("-" * 110)
    print(f"\nPolicy picks regime-best:        {n_correct}/{n_total} cells")
    print(f"Policy within 5% of regime-best: {n_near}/{n_total} cells")
    return 0 if n_near == n_total else 1


if __name__ == "__main__":
    raise SystemExit(main())
