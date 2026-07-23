#!/usr/bin/env python3
"""Analyse variance probe results (label='variance_probe_qb128_t96').

For each rep:
  - wall_s
  - clock_avg = cycles / (wall * 96 * 1e9)  — really (busy_cores × clock)/96
  - llc_loads, llc_misses, llc_miss%
  - instructions, ipc

Then test:
  1. Monotone-decreasing wall (thermal/DVFS through the sweep)
  2. Correlation between wall and (clock_avg, llc_misses, llc_miss%)
  3. Compare to original 5-rep distribution from main_56gb_query_batch_k128_supp
"""
from __future__ import annotations
import sqlite3
import statistics
import sys
from pathlib import Path

DB = Path(__file__).resolve().parent.parent / "logs" / "bench.db"

LABEL = sys.argv[1] if len(sys.argv) > 1 else "variance_probe_qb128_t96"


def fetch(label):
    c = sqlite3.connect(DB)
    c.row_factory = sqlite3.Row
    return list(c.execute("SELECT * FROM runs WHERE label=? ORDER BY id", (label,)))


def per_rep_summary(rows):
    print(f"{'rep':>3} {'wall_s':>7} {'ipc':>5} {'clock_calc':>10} {'llc_miss%':>9} {'l1_miss(G)':>10} {'instr(T)':>8}")
    print("-" * 60)
    for r in rows:
        clock = r['cycles'] / (r['wall_s'] * 96 * 1e9) if r['wall_s'] and r['cycles'] else 0
        miss_pct = (r['llc_misses'] / r['llc_loads'] * 100) if r['llc_loads'] else 0
        ipc = r['ipc'] or 0
        print(f"{r['repeat']:>3} {r['wall_s']:>7.2f} {ipc:>5.2f} {clock:>10.3f} {miss_pct:>8.1f}% "
              f"{(r['l1_misses'] or 0)/1e9:>10.2f} {(r['instructions'] or 0)/1e12:>8.3f}")


def correlation(xs, ys):
    if len(xs) < 2:
        return 0
    mx = statistics.mean(xs); my = statistics.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den_x = sum((x - mx) ** 2 for x in xs)
    den_y = sum((y - my) ** 2 for y in ys)
    if den_x == 0 or den_y == 0:
        return 0
    return num / (den_x * den_y) ** 0.5


def main():
    rows = fetch(LABEL)
    if not rows:
        print(f"no rows for label={LABEL!r}")
        sys.exit(1)
    print(f"\n=== {LABEL} (n={len(rows)}) ===")
    per_rep_summary(rows)

    walls = [r['wall_s'] for r in rows]
    clocks = [r['cycles'] / (r['wall_s'] * 96 * 1e9) if r['wall_s'] and r['cycles'] else 0 for r in rows]
    llc_miss_pct = [(r['llc_misses'] / r['llc_loads'] * 100) if r['llc_loads'] else 0 for r in rows]
    llc_misses = [(r['llc_misses'] or 0) for r in rows]
    instructions = [(r['instructions'] or 0) for r in rows]
    reps = [r['repeat'] for r in rows]

    print()
    print(f"  wall_s: median={statistics.median(walls):.2f} mean={statistics.mean(walls):.2f} "
          f"stdev={statistics.stdev(walls) if len(walls) > 1 else 0:.2f} "
          f"min={min(walls):.2f} max={max(walls):.2f}  spread={(max(walls)-min(walls))/statistics.median(walls)*100:.1f}%")
    print(f"  instr: stdev/mean = {statistics.stdev(instructions)/statistics.mean(instructions)*100 if len(instructions) > 1 else 0:.2f}%  (low → workload identical)")

    # Tests:
    # 1. Monotone wall: corr(wall, rep_idx) — positive = wall grows with rep number
    print()
    print("Correlation tests:")
    print(f"  corr(wall, rep_idx)        = {correlation(reps, walls):+.3f}  (positive → thermal/DVFS pattern)")
    print(f"  corr(wall, clock_calc)     = {correlation(walls, clocks):+.3f}  (negative → wall up when clock down)")
    print(f"  corr(wall, llc_miss%)      = {correlation(walls, llc_miss_pct):+.3f}  (positive → LLC pressure correlates)")
    print(f"  corr(wall, llc_misses)     = {correlation(walls, llc_misses):+.3f}")
    print(f"  corr(wall, instructions)   = {correlation(walls, instructions):+.3f}  (positive → workload-divergent; low → no)")


if __name__ == "__main__":
    main()
