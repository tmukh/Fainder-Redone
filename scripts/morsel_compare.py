#!/usr/bin/env python3
"""Print morsel vs query-batch K=128 / bestofsuite / packed-ids / default
medians on c256_56gb at t=32/64/96, with %-deltas vs each baseline.
"""
from __future__ import annotations
import sqlite3
import statistics
import sys
from pathlib import Path

DB = Path(__file__).resolve().parent.parent / "logs" / "bench.db"

SIZE = sys.argv[1] if len(sys.argv) > 1 else "56gb"
THREADS = [32, 64, 96]
BASELINES = [
    ("default",         "default"),
    ("packed-ids",      "packed_ids"),
    ("bestofsuite",     "bestofsuite"),
    ("qbatch K=64",     "query_batch"),
    ("qbatch K=128",    "query_batch_k128"),
    ("morsel",          "morsel"),
]


def med(con, label, build, t):
    rows = list(con.execute(
        "SELECT wall_s FROM runs WHERE label=? AND build=? AND threads=?",
        (label, build, t),
    ))
    if not rows:
        return None
    return statistics.median(r[0] for r in rows)


def main():
    con = sqlite3.connect(DB)
    print(f"\nc256_{SIZE} — median wall_s (suppress), n_reps in parens\n")
    header = f"{'engine':>16} | " + " | ".join(f"{f't={t}':>14}" for t in THREADS)
    print(header)
    print("-" * len(header))

    rows = {}
    for label, build in BASELINES:
        label_full = f"main_{SIZE}_{build}_supp"
        cells = []
        for t in THREADS:
            ws = list(con.execute(
                "SELECT wall_s FROM runs WHERE label=? AND build=? AND threads=?",
                (label_full, build, t),
            ))
            if not ws:
                cells.append((None, 0))
                continue
            walls = [w[0] for w in ws]
            cells.append((statistics.median(walls), len(walls)))
        rows[label] = cells
        cell_strs = [f"{c[0]:>10.2f}s ({c[1]})" if c[0] is not None else f"{'(no data)':>14}" for c in cells]
        print(f"{label:>16} | " + " | ".join(cell_strs))

    # If morsel exists, print delta vs each baseline at each t.
    if "morsel" not in rows or all(c[0] is None for c in rows["morsel"]):
        return
    print()
    print(f"morsel %-delta (negative = morsel faster):")
    delta_header = f"{'vs':>16} | " + " | ".join(f"{f't={t}':>10}" for t in THREADS)
    print(delta_header)
    print("-" * len(delta_header))
    for label, _ in BASELINES:
        if label == "morsel":
            continue
        deltas = []
        for i, t in enumerate(THREADS):
            base = rows[label][i][0]
            mor = rows["morsel"][i][0]
            if base is None or mor is None:
                deltas.append("-")
            else:
                pct = (mor - base) / base * 100
                deltas.append(f"{pct:>+9.1f}%")
        print(f"{label:>16} | " + " | ".join(f"{d:>10}" for d in deltas))


if __name__ == "__main__":
    main()
