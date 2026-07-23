#!/usr/bin/env python3
"""OOD structural-reproduction analyser for c1024_56gb (Phase 4).

For each of the four ceilings and the five negative-composability
instances, compare c1024_56gb's measurement to the c256_56gb baseline
(retrieved from bench.db where available, hardcoded from RESULTS.md
where not). Reports per-claim reproduction status.

Reproduction criterion:
  - Ceiling claims: same sign of effect as c256_56gb (e.g. f16 wins
    at t=16, aos doesn't, simd is null).
  - Neg-composability claims: same sign of regression (composed
    baseline + finer ablation > composed baseline alone).
  - Quantitative reproduction is reported but not required for
    confirmation: density may shift magnitude without breaking the
    structural claim.

Usage:
    scripts/analyse_ood_structural.py
"""
from __future__ import annotations
import sqlite3
import statistics
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB = REPO / "logs" / "bench.db"


def med(con, label, build, t):
    rows = list(con.execute(
        "SELECT wall_s FROM runs WHERE label=? AND build=? AND threads=?",
        (label, build, t)))
    return statistics.median(r[0] for r in rows) if rows else None


def pct(new, old):
    if old is None or new is None:
        return None
    return (new - old) / old * 100


def fmt(x, suffix="s"):
    return f"{x:.2f}{suffix}" if x is not None else "—"


def main():
    con = sqlite3.connect(DB)
    print(f"{'='*78}\nOOD structural validation — c1024_56gb vs c256_56gb\n{'='*78}\n")

    # ==========================================================
    # Group (A) — Ceiling (ii) shared L3
    # ==========================================================
    print("--- Group (A): Ceiling (ii) shared L3 ---\n")
    print("Claim: at t=16, footprint-reducing optimisations win and footprint-")
    print("expanding ones don't.  c256_56gb: f16 +40 % win, aos within noise.\n")
    print(f"{'build':>20} | {'c1024 t=16':>11} | {'c1024 default t=16':>20} | {'delta':>8} | reading")
    print("-" * 90)

    # c1024 default at t=16 from existing Phase 2 data.
    c1024_default_t16 = med(con, "ood_c1024_56gb_default", "ood_default", 16)
    if c1024_default_t16 is None:
        print("WARN: no c1024 default t=16 baseline; cannot compute relative wins")

    for build, label in [("ood_f16", "ood_c1024_56gb_f16"),
                        ("ood_aos", "ood_c1024_56gb_aos")]:
        w = med(con, label, build, 16)
        if w is None or c1024_default_t16 is None:
            print(f"{build:>20} | {fmt(w):>11} | {fmt(c1024_default_t16):>20} | {'—':>8} | (no data yet)")
            continue
        delta = pct(w, c1024_default_t16)
        reading = "footprint-shrinker WIN" if delta < -10 else \
                  "footprint-expander LOSE" if delta > 10 else "neutral"
        print(f"{build:>20} | {fmt(w):>11} | {fmt(c1024_default_t16):>20} | {delta:>+7.1f}% | {reading}")
    print()

    # ==========================================================
    # Group (B) — Negative-composability cross-density
    # ==========================================================
    print("--- Group (B): negative-composability cross-density ---\n")
    print("Claim: each composition regresses against the already-composed baseline.")
    print("c256_56gb signs: §3.7.6 NEG; §3.9.7 NEG; §3.10 NEG; §3.11 catastrophic NEG.\n")

    # §3.7.6: bestofsuite ← packed-ids
    print("[§3.7.6] bestofsuite ← packed-ids")
    print(f"  {'t':>4} | {'bestofsuite':>11} | {'+ packed-ids':>13} | {'delta':>8}")
    print(f"  {'-'*4}-+-{'-'*11}-+-{'-'*13}-+-{'-'*8}")
    for t in [8, 16, 32, 64, 96]:
        bs = med(con, "ood_c1024_56gb_bestofsuite", "ood_bestofsuite", t)
        cmp = med(con, "ood_c1024_56gb_bs_packed_ids", "ood_bs_packed_ids", t)
        d = pct(cmp, bs)
        sign = "(NEG)" if d is not None and d > 0 else "(POS)" if d is not None and d < 0 else ""
        print(f"  {t:>4} | {fmt(bs):>11} | {fmt(cmp):>13} | {f'{d:+.1f}%' if d is not None else '—':>8} {sign}")
    print()

    # §3.9.7: bestofsuite ← query-batch K=128
    print("[§3.9.7] bestofsuite ← query-batch K=128")
    print(f"  {'t':>4} | {'bestofsuite':>11} | {'+ qbatch K128':>13} | {'delta':>8}")
    print(f"  {'-'*4}-+-{'-'*11}-+-{'-'*13}-+-{'-'*8}")
    for t in [8, 16, 32, 64, 96]:
        bs = med(con, "ood_c1024_56gb_bestofsuite", "ood_bestofsuite", t)
        cmp = med(con, "ood_c1024_56gb_bs_qbatch_K128", "ood_bs_qbatch_K128", t)
        d = pct(cmp, bs)
        sign = "(NEG)" if d is not None and d > 0 else "(POS)" if d is not None and d < 0 else ""
        print(f"  {t:>4} | {fmt(bs):>11} | {fmt(cmp):>13} | {f'{d:+.1f}%' if d is not None else '—':>8} {sign}")
    print()

    # §3.10: query-batch K=128 ← morsel
    print("[§3.10] qbatch K=128 ← morsel")
    print(f"  {'t':>4} | {'qbatch K=128':>12} | {'+ morsel':>10} | {'delta':>8}")
    print(f"  {'-'*4}-+-{'-'*12}-+-{'-'*10}-+-{'-'*8}")
    for t in [8, 16, 32, 64, 96]:
        qb = med(con, "ood_c1024_56gb_qbatch_K128", "ood_qbatch_K128", t)
        mr = med(con, "ood_c1024_56gb_morsel_K128", "ood_morsel_K128", t)
        d = pct(mr, qb)
        sign = "(NEG)" if d is not None and d > 0 else "(POS)" if d is not None and d < 0 else ""
        print(f"  {t:>4} | {fmt(qb):>12} | {fmt(mr):>10} | {f'{d:+.1f}%' if d is not None else '—':>8} {sign}")
    print()

    # §3.11: packed-ids ← local-ids
    print("[§3.11] packed-ids ← local-ids / local-ids-bench")
    print(f"  {'t':>4} | {'packed-ids':>11} | {'local-ids':>10} | {'gap':>8} | {'bench':>10} | {'gap':>8}")
    print(f"  {'-'*4}-+-{'-'*11}-+-{'-'*10}-+-{'-'*8}-+-{'-'*10}-+-{'-'*8}")
    for t in [8, 16, 32, 64, 96]:
        pk = med(con, "ood_c1024_56gb_packed_ids", "ood_packed_ids", t)
        li = med(con, "ood_c1024_56gb_local_ids", "ood_local_ids", t)
        lb = med(con, "ood_c1024_56gb_local_ids_bench", "ood_local_ids_bench", t)
        dli = pct(li, pk)
        dlb = pct(lb, pk)
        print(f"  {t:>4} | {fmt(pk):>11} | {fmt(li):>10} | "
              f"{f'{dli:+.1f}%' if dli is not None else '—':>8} | "
              f"{fmt(lb):>10} | {f'{dlb:+.1f}%' if dlb is not None else '—':>8}")
    print()

    # §3.12: first-touch ← interleave
    print("[§3.12] unpinned (first-touch) ← numactl --interleave=0,1")
    print(f"  {'t':>4} | {'unpinned':>9} | {'interleave':>10} | {'delta':>8}")
    print(f"  {'-'*4}-+-{'-'*9}-+-{'-'*10}-+-{'-'*8}")
    for t in [32, 48, 64, 96]:
        un = med(con, "ood_c1024_56gb_packed_ids", "ood_packed_ids", t)
        il = med(con, "ood_c1024_56gb_packed_ids_interleave", "ood_packed_ids_interleave", t)
        d = pct(il, un)
        sign = "(NEG)" if d is not None and d > 0 else "(POS)" if d is not None and d < 0 else ""
        print(f"  {t:>4} | {fmt(un):>9} | {fmt(il):>10} | {f'{d:+.1f}%' if d is not None else '—':>8} {sign}")
    print()

    # ==========================================================
    # Group (C) — Ceiling (i) latency null spot-check
    # ==========================================================
    print("--- Group (C): Ceiling (i) latency null ---\n")
    print("Claim: SIMD provides no meaningful benefit (workload is L1-resident-CMOV-bound).\n")
    print(f"  {'t':>4} | {'default':>9} | {'simd':>9} | {'delta':>8}")
    print(f"  {'-'*4}-+-{'-'*9}-+-{'-'*9}-+-{'-'*8}")
    for t in [1, 8, 16, 32, 64, 96]:
        d_w = med(con, "ood_c1024_56gb_default", "ood_default", t)
        s_w = med(con, "ood_c1024_56gb_simd", "ood_simd", t)
        d = pct(s_w, d_w)
        reading = "(null/marginal)" if d is not None and abs(d) < 5 else \
                  "(WIN)" if d is not None and d < -5 else \
                  "(LOSE)" if d is not None and d > 5 else ""
        print(f"  {t:>4} | {fmt(d_w):>9} | {fmt(s_w):>9} | {f'{d:+.1f}%' if d is not None else '—':>8} {reading}")
    print()

    # ==========================================================
    # Group (D) — Ceiling (iv) cross-socket UPI at c1024
    # ==========================================================
    print("--- Group (D): Ceiling (iv) cross-socket UPI ---\n")
    print("Claim: single-socket placement wins; interleave regresses.")
    print("c256_56gb: single-socket -11-13 % at t<=48; interleave +26-41 % everywhere.\n")
    print(f"  {'t':>4} | {'unpinned':>9} | {'single-socket':>13} | {'gap':>8}")
    print(f"  {'-'*4}-+-{'-'*9}-+-{'-'*13}-+-{'-'*8}")
    for t in [32, 48]:
        un = med(con, "ood_c1024_56gb_packed_ids", "ood_packed_ids", t)
        ss = med(con, "ood_c1024_56gb_packed_ids_single_socket", "ood_packed_ids_single_socket", t)
        d = pct(ss, un)
        sign = "(WIN)" if d is not None and d < -5 else "(neutral)" if d is not None else ""
        print(f"  {t:>4} | {fmt(un):>9} | {fmt(ss):>13} | {f'{d:+.1f}%' if d is not None else '—':>8} {sign}")

    print(f"\n{'='*78}")
    print("Reading: each claim is reproduced at K=1024 iff its sign matches c256_56gb.")
    print("Magnitude shifts are acceptable; they map onto the histograms_per_cluster axis.")
    print(f"{'='*78}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
