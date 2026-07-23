#!/usr/bin/env python3
"""Step (1) gate-decision report.

Reads the bench.db rows tagged label LIKE 'step1_%' and prints a per-build
table of (with_s, supp_s, merge_s, merge_pct, mean_|S|), then applies the
decision rule.
"""
from __future__ import annotations
import sqlite3
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "logs" / "bench.db"


def median(xs):
    xs = sorted(xs)
    n = len(xs)
    if n == 0:
        return None
    return xs[n // 2] if n % 2 == 1 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def main() -> None:
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row

    rows = con.execute(
        """
        SELECT build, suppress_results, wall_s, result_mean
        FROM runs
        WHERE label LIKE 'step1_%' AND threads = 16
        """
    ).fetchall()
    if not rows:
        print("No step1_* rows found yet. Run scripts/step1_merge_gate.sh first.")
        return

    # Group by build, split by suppress_results
    by_build: dict[str, dict[int, list[sqlite3.Row]]] = {}
    for r in rows:
        by_build.setdefault(r["build"], {0: [], 1: []})[r["suppress_results"]].append(r)

    header = f"{'build':<14} {'with_s':>8} {'supp_s':>8} {'merge_s':>8} {'merge%':>7} {'mean|S|':>9}"
    print()
    print(header)
    print("-" * len(header))

    decisions = []
    for build, grp in sorted(by_build.items()):
        with_runs = grp.get(0, [])
        supp_runs = grp.get(1, [])
        if not with_runs or not supp_runs:
            print(f"{build:<14}   (incomplete: with={len(with_runs)} supp={len(supp_runs)})")
            continue
        # Use median of repeats — robust to one slow startup run.
        with_s = median(r["wall_s"] for r in with_runs)
        supp_s = median(r["wall_s"] for r in supp_runs)
        merge_s = with_s - supp_s
        merge_pct = (merge_s / with_s * 100) if with_s > 0 else 0.0
        mean_S_vals = [r["result_mean"] for r in with_runs if r["result_mean"] is not None]
        mean_S = median(mean_S_vals) if mean_S_vals else None
        mean_S_str = f"{mean_S:9.0f}" if mean_S is not None else f"{'—':>9}"

        print(f"{build:<14} {with_s:8.4f} {supp_s:8.4f} {merge_s:8.4f} {merge_pct:6.1f}% {mean_S_str}")
        decisions.append((build, merge_pct, mean_S))

    print()
    print("Decision rule:")
    print("  merge%  > 30%  →  step (2): Roaring")
    print("  merge%  ≤ 15%  →  footnote, ship search-phase story")
    print("  in-between     →  judgement call, look at mean|S|")
    print()

    max_pct = max((p for _, p, _ in decisions), default=0)
    if max_pct > 30:
        worst = max(decisions, key=lambda x: x[1])
        print(f"VERDICT: PROCEED to step (2). Worst-case merge share is {worst[1]:.1f}% on {worst[0]!r}.")
    elif max_pct <= 15:
        print(f"VERDICT: FOOTNOTE. Highest merge share is {max_pct:.1f}% across all builds.")
    else:
        print(f"VERDICT: AMBIGUOUS. Highest merge share is {max_pct:.1f}%. "
              f"Consider mean|S| values: large means → Roaring still likely helps; "
              f"small means → per-ID materialisation cost dominates, fix that instead.")


if __name__ == "__main__":
    main()
