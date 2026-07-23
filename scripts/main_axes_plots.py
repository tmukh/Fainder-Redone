#!/usr/bin/env python3
"""Generate plots for the main-axes campaign.

Output PNGs to docs/figures/. One file per plot:
  strong_scaling_default.png   — §3.3.1
  ipc_vs_threads_default.png   — §3.3 perf companion
  speedup_simd.png             — §3.1
  speedup_soa.png              — §3.2 (default / aos)
  speedup_pgm.png              — §3.6
  speedup_packed.png           — §3.7
  speedup_qbatch.png           — §3.9
  dispatch_summary.png         — §3.9.9 (best engine per regime cell)
  end_to_end_bestofsuite.png   — §5

Reads only the median per cell; relies on logs/bench.db rows whose
label LIKE 'main_%'.
"""
from __future__ import annotations
import sqlite3
import statistics
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

DB = Path(__file__).resolve().parent.parent / "logs" / "bench.db"
OUT = Path(__file__).resolve().parent.parent / "docs" / "figures"
OUT.mkdir(parents=True, exist_ok=True)

SIZES = ["10gb", "30gb", "56gb"]
THREADS = [1, 8, 16, 32, 64, 96]
COLOURS = {"10gb": "#1f77b4", "30gb": "#ff7f0e", "56gb": "#2ca02c"}


def median(xs):
    xs = sorted(x for x in xs if x is not None)
    if not xs:
        return None
    n = len(xs)
    return xs[n // 2] if n % 2 else 0.5 * (xs[n // 2 - 1] + xs[n // 2])


def parse_label(label):
    if not label or not label.startswith("main_"):
        return None
    parts = label[len("main_"):].split("_")
    if len(parts) < 3:
        return None
    return parts[0], parts[1], parts[2]


def fetch_grouped():
    con = sqlite3.connect(DB)
    con.row_factory = sqlite3.Row
    rows = con.execute("SELECT * FROM runs WHERE label LIKE 'main_%'").fetchall()
    g = {}
    for r in rows:
        meta = parse_label(r["label"])
        if not meta:
            continue
        size, build, regime = meta
        g.setdefault((size, build, regime, r["threads"]), []).append(dict(r))
    return g


def med_for(g, size, build, regime, t, key="wall_s"):
    rs = g.get((size, build, regime, t), [])
    if not rs:
        return None
    return median([r.get(key) for r in rs if r.get(key) is not None])


def plot_strong_scaling(g):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for size in SIZES:
        ys = [med_for(g, size, "default", "supp", t) for t in THREADS]
        if all(y is None for y in ys):
            continue
        ax.plot(THREADS, ys, marker="o", color=COLOURS[size], label=f"c256_{size}")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(THREADS); ax.set_xticklabels([str(t) for t in THREADS])
    ax.set_xlabel("threads")
    ax.set_ylabel("wall (s) — median, lower is better")
    ax.set_title("Strong-scaling — Rust default (suppress-results)")
    ax.grid(which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(OUT / "strong_scaling_default.png", dpi=140)
    plt.close(fig)


def plot_ipc_vs_threads(g):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for size in SIZES:
        ys = [med_for(g, size, "default", "supp", t, "ipc") for t in THREADS]
        if all(y is None for y in ys):
            continue
        ax.plot(THREADS, ys, marker="s", color=COLOURS[size], label=f"c256_{size}")
    ax.set_xscale("log", base=2)
    ax.set_xticks(THREADS); ax.set_xticklabels([str(t) for t in THREADS])
    ax.set_xlabel("threads")
    ax.set_ylabel("IPC (median)")
    ax.set_title("IPC vs threads — Rust default (suppress-results)")
    ax.grid(which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(OUT / "ipc_vs_threads_default.png", dpi=140)
    plt.close(fig)


def plot_speedup(g, build, regime, fname, title, denom=("default", "supp"), invert=False):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for size in SIZES:
        ratios = []
        for t in THREADS:
            num = med_for(g, size, build, regime, t)
            den = med_for(g, size, denom[0], denom[1], t)
            if num and den:
                ratios.append(den / num if not invert else num / den)
            else:
                ratios.append(None)
        if all(r is None for r in ratios):
            continue
        ax.plot(THREADS, ratios, marker="o", color=COLOURS[size], label=f"c256_{size}")
    ax.axhline(1.0, color="grey", linestyle="--", linewidth=0.8)
    ax.set_xscale("log", base=2)
    ax.set_xticks(THREADS); ax.set_xticklabels([str(t) for t in THREADS])
    ax.set_xlabel("threads")
    ax.set_ylabel("speedup (× higher = wins more)")
    ax.set_title(title)
    ax.grid(which="both", alpha=0.3)
    ax.legend()
    fig.tight_layout()
    fig.savefig(OUT / fname, dpi=140)
    plt.close(fig)


def plot_end_to_end(g):
    fig, ax = plt.subplots(figsize=(7, 4.2))
    for size in SIZES:
        ys = [med_for(g, size, "bestofsuite", "with", t) for t in THREADS]
        if all(y is None for y in ys):
            continue
        ax.plot(THREADS, ys, marker="o", color=COLOURS[size], label=f"bestofsuite c256_{size}")
        py = [med_for(g, size, "python", "with", t) for t in THREADS]
        if any(p is not None for p in py):
            ax.plot(THREADS, py, marker="x", color=COLOURS[size], linestyle=":", alpha=0.7,
                    label=f"python c256_{size}")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xticks(THREADS); ax.set_xticklabels([str(t) for t in THREADS])
    ax.set_xlabel("threads")
    ax.set_ylabel("wall (s)")
    ax.set_title("End-to-end (with-results) — bestofsuite vs Python baseline")
    ax.grid(which="both", alpha=0.3)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(OUT / "end_to_end_bestofsuite.png", dpi=140)
    plt.close(fig)


def plot_dispatch_summary(g):
    """Heat-map style figure: best engine per (dataset, t) cell.

    For each cell, look up which build (default / packed / bestofsuite /
    qbatch / qbatch_k128) has the lowest median wall, and colour-code
    the cell by the engine name.
    """
    builds = ["default", "packed_ids", "bestofsuite", "query_batch", "query_batch_k128"]
    palette = {
        "default":          "#aec7e8",
        "packed_ids":       "#ff7f0e",
        "bestofsuite":      "#2ca02c",
        "query_batch":      "#d62728",
        "query_batch_k128": "#9467bd",
    }
    fig, ax = plt.subplots(figsize=(8, 3.6))
    cell_w, cell_h = 1.0, 1.0
    legend_seen = set()
    for j, size in enumerate(SIZES):
        for i, t in enumerate(THREADS):
            best_build, best_wall = None, float("inf")
            for b in builds:
                w = med_for(g, size, b, "supp", t)
                if w is not None and w < best_wall:
                    best_build, best_wall = b, w
            if best_build is None:
                continue
            colour = palette[best_build]
            ax.add_patch(plt.Rectangle((i, j), cell_w, cell_h,
                                        facecolor=colour, edgecolor="white", linewidth=1.5))
            label = f"{best_wall:.1f}s"
            ax.text(i + 0.5, j + 0.5, label, ha="center", va="center", fontsize=9, color="black")
    ax.set_xlim(0, len(THREADS)); ax.set_ylim(0, len(SIZES))
    ax.set_xticks([i + 0.5 for i in range(len(THREADS))])
    ax.set_xticklabels([str(t) for t in THREADS])
    ax.set_yticks([j + 0.5 for j in range(len(SIZES))])
    ax.set_yticklabels([f"c256_{s}" for s in SIZES])
    ax.set_xlabel("threads")
    ax.set_title("Regime-best engine (suppress; cell shows median wall in s)")
    handles = [plt.Rectangle((0, 0), 1, 1, facecolor=palette[b], label=b) for b in builds
               if any(med_for(g, s, b, "supp", t) is not None for s in SIZES for t in THREADS)]
    ax.legend(handles=handles, loc="center left", bbox_to_anchor=(1.02, 0.5), fontsize=9)
    ax.invert_yaxis()
    fig.tight_layout()
    fig.savefig(OUT / "dispatch_summary.png", dpi=140, bbox_inches="tight")
    plt.close(fig)


def main():
    g = fetch_grouped()
    if not g:
        print("No main_* rows in bench.db.")
        sys.exit(0)
    plot_strong_scaling(g)
    plot_ipc_vs_threads(g)
    plot_speedup(g, "simd", "supp", "speedup_simd.png",
                 "SIMD speedup vs default (suppress)")
    plot_speedup(g, "default", "supp", "speedup_soa.png",
                 "SoA wins: default / aos (suppress; > 1 = SoA faster)",
                 denom=("aos", "supp"))
    plot_speedup(g, "pgm", "supp", "speedup_pgm.png",
                 "PGM speedup vs default (suppress; > 1 = PGM faster)")
    plot_speedup(g, "packed_ids", "supp", "speedup_packed.png",
                 "packed-ids speedup vs default (suppress; > 1 = packed-ids faster)")
    plot_speedup(g, "query_batch", "supp", "speedup_qbatch.png",
                 "query-batch K=64 speedup vs default (suppress; > 1 = qbatch faster)")
    plot_dispatch_summary(g)
    plot_end_to_end(g)
    print(f"Plots written to {OUT}/")


if __name__ == "__main__":
    main()
