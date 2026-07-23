#!/usr/bin/env python3
"""Post-process the full ablation campaign.

Reads bench.db rows tagged label LIKE 'campaign_%' and prints:
  1. Per-(build × threads) median wall_s — separate tables for suppress and with-results.
  2. Speedup vs `default` baseline at each thread count.
  3. With-results merge share per (build × threads).
  4. Pretty CSV dump for plot scripts (logs/campaign_summary.csv).
"""
from __future__ import annotations
import sqlite3
import sys
import statistics
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "logs" / "bench.db"
CSV_OUT = Path(__file__).resolve().parent.parent / "logs" / "campaign_summary.csv"


def fetch_rows():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con.execute(
        """
        SELECT build, threads, suppress_results, wall_s, ipc, result_mean, result_total
        FROM runs
        WHERE label LIKE 'campaign_%'
        """
    ).fetchall()


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def aggregate(rows):
    """Group by (build, threads, suppress) → list of wall_s. Return medians."""
    by_key: dict[tuple, list[float]] = {}
    extra: dict[tuple, list[float]] = {}
    for r in rows:
        key = (r["build"], r["threads"], r["suppress_results"])
        by_key.setdefault(key, []).append(r["wall_s"])
        if r["result_mean"] is not None:
            extra.setdefault(key, []).append(r["result_mean"])
    return {k: (median(v), median(extra.get(k, []))) for k, v in by_key.items()}


def print_table(stats, suppress, threads_list, builds_in_order):
    label = "suppress-results (search-phase isolation)" if suppress else "with-results (full pipeline)"
    print()
    print(f"=== {label} — median wall_s by build × threads ===")
    header = f"{'build':<32}" + "".join(f"{f't={t}':>10}" for t in threads_list)
    print(header)
    print("-" * len(header))
    for b in builds_in_order:
        row = [b]
        for t in threads_list:
            wall, _ = stats.get((b, t, suppress), (None, None))
            row.append(f"{wall:9.3f}s" if wall is not None else f"{'—':>9}")
        print(f"{row[0]:<32}" + "".join(f"{c:>10}" for c in row[1:]))


def print_speedup_table(stats, suppress, threads_list, builds_in_order, baseline="default"):
    print()
    label = "suppress-results" if suppress else "with-results"
    print(f"=== Speedup vs {baseline} ({label}) — higher is better ===")
    header = f"{'build':<32}" + "".join(f"{f't={t}':>10}" for t in threads_list)
    print(header)
    print("-" * len(header))
    for b in builds_in_order:
        row = [b]
        for t in threads_list:
            wall, _ = stats.get((b, t, suppress), (None, None))
            base, _ = stats.get((baseline, t, suppress), (None, None))
            if wall and base and wall > 0:
                row.append(f"{base / wall:>8.2f}×")
            else:
                row.append(f"{'—':>9}")
        print(f"{row[0]:<32}" + "".join(f"{c:>10}" for c in row[1:]))


def print_merge_share_table(stats, threads_list, builds_in_order):
    print()
    print("=== Merge-phase share of with-results wall (with - supp) / with × 100% ===")
    print("    Negative values are within run-to-run variance; treat as ~0%.")
    header = f"{'build':<32}" + "".join(f"{f't={t}':>10}" for t in threads_list)
    print(header)
    print("-" * len(header))
    for b in builds_in_order:
        row = [b]
        for t in threads_list:
            with_s, _ = stats.get((b, t, 0), (None, None))
            supp_s, _ = stats.get((b, t, 1), (None, None))
            if with_s and supp_s and with_s > 0:
                pct = (with_s - supp_s) / with_s * 100
                row.append(f"{pct:>7.1f}%")
            else:
                row.append(f"{'—':>9}")
        print(f"{row[0]:<32}" + "".join(f"{c:>10}" for c in row[1:]))


def write_csv(rows, stats, threads_list):
    """Flat CSV for downstream plot scripts: build, threads, suppress, wall_s_median, mean_S."""
    builds = sorted({r["build"] for r in rows})
    with open(CSV_OUT, "w") as f:
        f.write("build,threads,suppress_results,wall_s_median,mean_S\n")
        for b in builds:
            for t in threads_list:
                for s in (0, 1):
                    wall, mean_S = stats.get((b, t, s), (None, None))
                    if wall is not None:
                        f.write(f"{b},{t},{s},{wall:.6f},{mean_S if mean_S else ''}\n")
    print(f"\nCSV written to {CSV_OUT}")


def main():
    rows = fetch_rows()
    if not rows:
        print("No campaign_* rows found yet.")
        sys.exit(0)

    stats = aggregate(rows)
    threads_list = sorted({r["threads"] for r in rows})
    builds_seen = sorted({r["build"] for r in rows})

    # Order: default first (baseline), then singletons alphabetically, then combined.
    combined_prefix = ("pooled-f16", "bestofsuite")
    singletons = [b for b in builds_seen if not any(b.startswith(p) for p in combined_prefix) and b != "default"]
    combined = [b for b in builds_seen if any(b.startswith(p) for p in combined_prefix)]
    order = ["default"] + sorted(singletons) + sorted(combined)
    order = [b for b in order if b in builds_seen]

    n_runs = len(rows)
    n_complete = sum(1 for k, v in stats.items() if v[0] is not None)
    print(f"Campaign rows: {n_runs} (covering {len(builds_seen)} builds × {len(threads_list)} thread counts)")

    print_table(stats, suppress=1, threads_list=threads_list, builds_in_order=order)
    print_table(stats, suppress=0, threads_list=threads_list, builds_in_order=order)
    print_speedup_table(stats, suppress=1, threads_list=threads_list, builds_in_order=order)
    print_speedup_table(stats, suppress=0, threads_list=threads_list, builds_in_order=order)
    print_merge_share_table(stats, threads_list=threads_list, builds_in_order=order)
    write_csv(rows, stats, threads_list)


if __name__ == "__main__":
    main()
