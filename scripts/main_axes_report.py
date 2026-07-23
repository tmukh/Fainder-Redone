#!/usr/bin/env python3
"""Post-process the main-axes campaign.

Reads `logs/bench.db` rows tagged label LIKE 'main_%' and emits markdown tables
matching the placeholders in `docs/RESULTS.md`:
  • §2.1 Python baseline wall-clock × dataset × threads
  • §2.2 Python baseline perf counters at t=16
  • §3.1.1 SIMD speedup vs default (suppress) per dataset × threads
  • §3.2.1 SoA-vs-AoS speedup (default / aos) per dataset × threads
  • §3.3.1 Strong-scaling for default per dataset × threads
  • §5    bestofsuite (with-results) per dataset × threads + speedup vs Python

Tables are printed to stdout — paste into RESULTS.md.
"""
from __future__ import annotations
import sqlite3
import statistics
import re
from pathlib import Path

DB_PATH = Path(__file__).resolve().parent.parent / "logs" / "bench.db"

LABEL_RE = re.compile(r"^main_(?P<size>10gb|30gb|56gb)_(?P<build>\w+)_(?P<regime>with|supp)$")
SIZES = ("10gb", "30gb", "56gb")
THREADS = (1, 8, 16, 32, 64, 96)


def fetch():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con.execute(
        """
        SELECT label, build, threads, suppress_results, wall_s,
               ipc, cache_misses, llc_misses, branch_misses, cycles, instructions
        FROM runs
        WHERE label LIKE 'main_%'
        """
    ).fetchall()


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    return statistics.median(xs)


def aggregate(rows):
    """(size, build, threads) -> dict of medians."""
    by_key: dict[tuple, dict[str, list[float]]] = {}
    for r in rows:
        m = LABEL_RE.match(r["label"] or "")
        if not m:
            continue
        size = m["size"]
        build = m["build"]
        key = (size, build, r["threads"])
        d = by_key.setdefault(key, {"wall": [], "ipc": [], "cm": [], "lm": [], "bm": [], "cyc": [], "ins": []})
        d["wall"].append(r["wall_s"])
        d["ipc"].append(r["ipc"])
        d["cm"].append(r["cache_misses"])
        d["lm"].append(r["llc_misses"])
        d["bm"].append(r["branch_misses"])
        d["cyc"].append(r["cycles"])
        d["ins"].append(r["instructions"])
    return {
        k: {kk: median(vv) for kk, vv in v.items()} for k, v in by_key.items()
    }


def fmt(x, unit="s", digits=3):
    if x is None:
        return "_TBD_"
    return f"{x:.{digits}f}{unit}"


def fmt_speedup(num, den):
    if num is None or den is None or num <= 0:
        return "_TBD_"
    return f"{den / num:.2f}×"


def print_table(title, header_cols, rows):
    print(f"\n### {title}\n")
    print("| " + " | ".join(header_cols) + " |")
    print("|" + "|".join(["---"] * len(header_cols)) + "|")
    for row in rows:
        print("| " + " | ".join(row) + " |")


def section_2_1_python_walls(stats):
    head = ["Dataset"] + [f"t={t}" for t in THREADS]
    rows = []
    for size in SIZES:
        row = [f"`c256_{size}`"]
        for t in THREADS:
            d = stats.get((size, "python", t), {})
            row.append(fmt(d.get("wall")))
        rows.append(row)
    print_table("§2.1 Python baseline — wall-clock × dataset × threads", head, rows)


def section_2_2_python_perf(stats):
    head = ["Dataset", "IPC", "LLC misses", "Branch misses", "Cycles", "Instructions"]
    rows = []
    for size in SIZES:
        d = stats.get((size, "python", 16), {})
        rows.append([
            f"`c256_{size}`",
            fmt(d.get("ipc"), unit="", digits=2),
            f"{int(d['lm']):,}" if d.get("lm") else "_TBD_",
            f"{int(d['bm']):,}" if d.get("bm") else "_TBD_",
            f"{int(d['cyc']):,}" if d.get("cyc") else "_TBD_",
            f"{int(d['ins']):,}" if d.get("ins") else "_TBD_",
        ])
    print_table("§2.2 Python baseline — perf counters at t=16", head, rows)


def section_3_1_simd_speedup(stats):
    head = ["Dataset"] + [f"t={t}" for t in THREADS]
    rows = []
    for size in SIZES:
        row = [f"`c256_{size}`"]
        for t in THREADS:
            d_def  = stats.get((size, "default", t), {})
            d_simd = stats.get((size, "simd", t), {})
            row.append(fmt_speedup(d_simd.get("wall"), d_def.get("wall")))
        rows.append(row)
    print_table("§3.1.1 SIMD speedup vs default (suppress)", head, rows)


def section_3_2_aos_vs_soa(stats):
    head = ["Dataset"] + [f"t={t}" for t in THREADS]
    rows = []
    for size in SIZES:
        row = [f"`c256_{size}`"]
        for t in THREADS:
            d_def = stats.get((size, "default", t), {})
            d_aos = stats.get((size, "aos", t), {})
            row.append(fmt_speedup(d_def.get("wall"), d_aos.get("wall")))
        rows.append(row)
    print_table("§3.2.1 SoA wins (= aos / default; higher = SoA wins more)", head, rows)


def section_3_3_strong_scaling(stats):
    head = ["Dataset"] + [f"t={t}" for t in THREADS] + ["t=8/t=1", "t=96/t=1"]
    rows = []
    for size in SIZES:
        row = [f"`c256_{size}`"]
        walls = {t: stats.get((size, "default", t), {}).get("wall") for t in THREADS}
        for t in THREADS:
            row.append(fmt(walls[t]))
        for ratio_pair in [(8, 1), (96, 1)]:
            num, den = walls[ratio_pair[0]], walls[ratio_pair[1]]
            row.append(fmt_speedup(num, den))
        rows.append(row)
    print_table("§3.3.1 Strong-scaling — default suppress, wall × t", head, rows)


def section_5_bestofsuite(stats):
    head = ["Dataset"] + [f"t={t}" for t in THREADS] + ["best speedup vs Python"]
    rows = []
    for size in SIZES:
        row = [f"`c256_{size}`"]
        py_walls = [stats.get((size, "python", t), {}).get("wall") for t in THREADS]
        bs_walls = [stats.get((size, "bestofsuite", t), {}).get("wall") for t in THREADS]
        for w in bs_walls:
            row.append(fmt(w))
        # Best speedup = min(bs) compared to corresponding python.
        valid = [(p, b) for p, b in zip(py_walls, bs_walls) if p and b]
        if valid:
            best_speed = max(p / b for p, b in valid)
            row.append(f"{best_speed:.1f}×")
        else:
            row.append("_TBD_")
        rows.append(row)
    print_table("§5 bestofsuite (with-results)", head, rows)


def main():
    rows = fetch()
    if not rows:
        print("No 'main_*' rows found in logs/bench.db.")
        return
    stats = aggregate(rows)
    n_keys = len(stats)
    n_rows = len(rows)
    print(f"# Main-axes campaign report — {n_rows} runs across {n_keys} (size,build,threads) cells\n")
    section_2_1_python_walls(stats)
    section_2_2_python_perf(stats)
    section_3_1_simd_speedup(stats)
    section_3_2_aos_vs_soa(stats)
    section_3_3_strong_scaling(stats)
    section_5_bestofsuite(stats)


if __name__ == "__main__":
    main()
