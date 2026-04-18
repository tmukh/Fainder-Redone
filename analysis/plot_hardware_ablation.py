"""
Generates figures for hardware-level ablation experiments:
  fig5_numa_vs_unpinned.pdf/png   — NUMA-pinned vs unpinned thread sweep
  fig6_tmpfs_vs_disk.pdf/png      — tmpfs vs disk (proves DRAM-bound, not I/O)
  fig7_soa_vs_aos.pdf/png         — SoA vs AoS across datasets and modes
  fig8_all_curves.pdf/png         — combined: disk / tmpfs / numa on one axes
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from pathlib import Path

OUT = Path("analysis/figures")
OUT.mkdir(parents=True, exist_ok=True)

plt.rcParams.update({
    "font.family": "serif", "font.size": 11,
    "axes.titlesize": 12, "axes.labelsize": 11,
    "xtick.labelsize": 10, "ytick.labelsize": 10,
    "legend.fontsize": 9, "figure.dpi": 150,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.alpha": 0.3, "grid.linestyle": "--",
})

THREADS = [1, 2, 4, 8, 16, 32, 64]
PYTHON  = 732.1   # eval_medium Python baseline

# ── Data ──────────────────────────────────────────────────────────────────────

unpinned = [565.5, 545.6, 553.3, 576.4, 570.3, 578.2, 556.5]
numa     = [529.7, 482.8, 477.4, 539.7, 549.0, 556.6, 551.4]
disk     = unpinned   # same experiment
tmpfs    = [726.4, 555.8, 543.3, 541.3, 541.8, 612.0, 558.8]

soa_aos = {
    # (dataset, mode): (soa_t, aos_t)
    ("dev_small",   "rebinning"):  (0.78,  0.84),
    ("dev_small",   "conversion"): (1.08,  1.14),
    ("eval_medium", "rebinning"):  (551.3, 541.6),
    ("eval_medium", "conversion"): (614.5, 608.5),
    ("eval_10gb",   "rebinning"):  (69.3,  69.3),
    ("eval_10gb",   "conversion"): (91.0,  82.8),
}

BLUE   = "#2166ac"
RED    = "#d6604d"
GREEN  = "#4dac26"
ORANGE = "#f4a582"
PURPLE = "#762a83"

def save(fig, name):
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"{name}.{ext}", dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {name}.pdf/.png")


# ── Fig 5: NUMA pinned vs unpinned ───────────────────────────────────────────
def fig5_numa():
    fig, ax = plt.subplots(figsize=(6.5, 4.2))

    ax.axhline(PYTHON, color=RED, linestyle="--", lw=1.3,
               label=f"Python baseline ({PYTHON:.0f}s)", alpha=0.7)
    ax.plot(THREADS, unpinned, color=BLUE, marker="o", lw=1.8, ms=6,
            label="Rust — unpinned (default)")
    ax.plot(THREADS, numa, color=GREEN, marker="s", lw=1.8, ms=6,
            label="Rust — NUMA-pinned (node 0)")

    # Annotate best NUMA improvement
    best_idx = int(np.argmin(numa))
    improvement = (unpinned[best_idx] - numa[best_idx]) / unpinned[best_idx] * 100
    ax.annotate(
        f"peak: {improvement:.0f}% faster\n(t={THREADS[best_idx]}, {numa[best_idx]:.0f}s)",
        xy=(THREADS[best_idx], numa[best_idx]),
        xytext=(THREADS[best_idx] + 4, numa[best_idx] - 60),
        fontsize=8.5, color=GREEN,
        arrowprops=dict(arrowstyle="->", color=GREEN, lw=1.1),
    )

    ax.set_xscale("log", base=2)
    ax.set_xticks(THREADS)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Rayon threads")
    ax.set_ylabel("Query execution time (s)")
    ax.set_title("NUMA topology effect — eval\\_medium\n"
                 "(numactl --membind=0 --cpunodebind=0 vs. default)")
    ax.legend()
    ax.set_ylim(0, PYTHON * 1.15)
    fig.tight_layout()
    save(fig, "fig5_numa_vs_unpinned")


# ── Fig 6: tmpfs vs disk ──────────────────────────────────────────────────────
def fig6_tmpfs():
    fig, ax = plt.subplots(figsize=(6.5, 4.2))

    ax.axhline(PYTHON, color=RED, linestyle="--", lw=1.3,
               label=f"Python baseline ({PYTHON:.0f}s)", alpha=0.7)
    ax.plot(THREADS, disk, color=BLUE, marker="o", lw=1.8, ms=6,
            label="Rust — index on disk (page cache)")
    ax.plot(THREADS, tmpfs, color=ORANGE, marker="^", lw=1.8, ms=6,
            label="Rust — index in tmpfs (/dev/shm)")

    # Ideal scaling reference
    ideal = [disk[0] / t for t in THREADS]
    ax.plot(THREADS, ideal, color=BLUE, linestyle=":", lw=1.1, alpha=0.35,
            label="Ideal linear scaling (ref)")

    ax.annotate("curves overlap →\nbottleneck is DRAM,\nnot I/O",
                xy=(16, np.mean(tmpfs[2:6])),
                xytext=(22, np.mean(tmpfs[2:6]) - 140),
                fontsize=8.5, color="gray",
                arrowprops=dict(arrowstyle="->", color="gray", lw=1.0))

    ax.set_xscale("log", base=2)
    ax.set_xticks(THREADS)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Rayon threads")
    ax.set_ylabel("Query execution time (s)")
    ax.set_title("tmpfs isolation — eval\\_medium (494 MB index)\n"
                 "Flat curve persists in RAM → bottleneck is DRAM bandwidth, not I/O")
    ax.legend()
    ax.set_ylim(0, PYTHON * 1.15)
    fig.tight_layout()
    save(fig, "fig6_tmpfs_vs_disk")


# ── Fig 7: SoA vs AoS ────────────────────────────────────────────────────────
def fig7_soa_aos():
    fig, axes = plt.subplots(1, 3, figsize=(13, 4.2), sharey=False)

    datasets = ["dev_small", "eval_medium", "eval_10gb"]
    titles   = ["dev\\_small\n(50k hists)", "eval\\_medium\n(200k hists)", "eval\\_10gb\n(323k hists)"]
    modes    = ["rebinning", "conversion"]
    x        = np.array([0, 1])
    w        = 0.3

    for ax, ds, title in zip(axes, datasets, titles):
        soa_times = [soa_aos[(ds, m)][0] for m in modes]
        aos_times = [soa_aos[(ds, m)][1] for m in modes]

        b1 = ax.bar(x - w/2, soa_times, w, label="SoA (default)", color=BLUE,   alpha=0.85)
        b2 = ax.bar(x + w/2, aos_times, w, label="AoS (control)", color=ORANGE, alpha=0.85)

        for bars in [b1, b2]:
            for bar in bars:
                h = bar.get_height()
                label = f"{h:.2f}s" if h < 10 else f"{h:.0f}s"
                ax.text(bar.get_x() + bar.get_width()/2, h * 1.02,
                        label, ha="center", va="bottom", fontsize=7.5)

        # Annotate % difference
        for i, (s, a) in enumerate(zip(soa_times, aos_times)):
            diff = (a - s) / s * 100
            sign = "+" if diff > 0 else ""
            ax.text(x[i], max(s, a) * 1.12, f"{sign}{diff:.0f}%",
                    ha="center", fontsize=8, color=GREEN if diff > 0 else RED)

        ax.set_xticks(x)
        ax.set_xticklabels(modes)
        ax.set_title(f"{title}")
        ax.set_ylabel("Query time (s)" if ax == axes[0] else "")
        ax.legend(fontsize=8)
        ax.spines["top"].set_visible(False)
        ax.spines["right"].set_visible(False)
        ax.grid(True, axis="y", alpha=0.3, linestyle="--")
        ax.grid(False, axis="x")

    fig.suptitle("SoA vs AoS memory layout — query execution time (t=1 serial)\n"
                 "Green % = AoS overhead; negative = AoS faster (layout not the bottleneck)",
                 fontsize=11, y=1.02)
    fig.tight_layout()
    save(fig, "fig7_soa_vs_aos")


# ── Fig 8: All curves on one plot ────────────────────────────────────────────
def fig8_all_curves():
    fig, ax = plt.subplots(figsize=(7.5, 4.5))

    ax.axhline(PYTHON, color=RED, linestyle="--", lw=1.2,
               label=f"Python baseline ({PYTHON:.0f}s)", alpha=0.6)
    ax.plot(THREADS, disk,  color=BLUE,   marker="o", lw=1.8, ms=5,
            label="Rust — disk (unpinned)")
    ax.plot(THREADS, tmpfs, color=ORANGE, marker="^", lw=1.8, ms=5,
            label="Rust — tmpfs (proves DRAM-bound)")
    ax.plot(THREADS, numa,  color=GREEN,  marker="s", lw=1.8, ms=5,
            label="Rust — NUMA-pinned (node 0)")

    ideal = [disk[0] / t for t in THREADS]
    ax.plot(THREADS, ideal, color=BLUE, linestyle=":", lw=1.0, alpha=0.3,
            label="Ideal linear scaling (ref)")

    ax.set_xscale("log", base=2)
    ax.set_xticks(THREADS)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Rayon threads")
    ax.set_ylabel("Query execution time (s)")
    ax.set_title("Hardware ablation summary — eval\\_medium (10k queries, 200k hists)\n"
                 "All three curves flat → bottleneck is DRAM latency, not I/O or NUMA topology")
    ax.legend(loc="upper right")
    ax.set_ylim(0, PYTHON * 1.15)
    fig.tight_layout()
    save(fig, "fig8_hardware_ablation_summary")


if __name__ == "__main__":
    print("Generating hardware ablation figures...")
    fig5_numa()
    fig6_tmpfs()
    fig7_soa_aos()
    fig8_all_curves()
    print(f"\nAll figures → {OUT.resolve()}")
