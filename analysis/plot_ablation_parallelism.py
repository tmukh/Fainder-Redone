"""
Generates two publication-quality figures for the thesis ablation study:

  Figure 1: dev_small thread sweep — shows peak at t=4, then degradation
  Figure 2: eval_medium thread sweep — flat line (memory-bandwidth bound)
  Figure 3: Combined side-by-side panel figure

Output: analysis/figures/ablation_*.pdf  (vector, for LaTeX)
        analysis/figures/ablation_*.png  (300 DPI, for preview)
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from pathlib import Path

OUT = Path("analysis/figures")
OUT.mkdir(parents=True, exist_ok=True)

# ── Measured data (from logs/ablation/) ──────────────────────────────────────

# dev_small: 200 queries, 50k histograms
dev_small = {
    "threads": [1, 2, 4, 8, 16, 32, 64],
    "times":   [0.7185, 0.6555, 0.4602, 0.6574, 0.7079, 0.6626, 0.7416],
    "python":  0.8371,
}

# eval_medium: 10 000 queries, 200k histograms (~494 MB index)
eval_medium = {
    "threads": [1, 2, 4, 8, 16, 32, 64],
    "times":   [548.20, 528.86, 537.02, 559.45, 553.33, 561.52, 539.53],
    "python":  732.05,
}

# ── Style ────────────────────────────────────────────────────────────────────
RUST_COLOR   = "#2166ac"   # blue  — Rust (Rayon)
PYTHON_COLOR = "#d6604d"   # red   — Python baseline
OPT_COLOR    = "#4dac26"   # green — annotate optimal point

plt.rcParams.update({
    "font.family":      "serif",
    "font.size":        11,
    "axes.titlesize":   12,
    "axes.labelsize":   11,
    "xtick.labelsize":  10,
    "ytick.labelsize":  10,
    "legend.fontsize":  10,
    "figure.dpi":       150,
    "axes.spines.top":  False,
    "axes.spines.right":False,
    "axes.grid":        True,
    "grid.alpha":       0.3,
    "grid.linestyle":   "--",
})

# ── Figure 1: dev_small ───────────────────────────────────────────────────────
def plot_dev_small():
    threads = dev_small["threads"]
    times   = dev_small["times"]
    python  = dev_small["python"]
    opt_idx = int(np.argmin(times))

    fig, ax = plt.subplots(figsize=(5.5, 3.8))

    # Python baseline (horizontal dashed)
    ax.axhline(python, color=PYTHON_COLOR, linestyle="--", linewidth=1.4,
               label=f"Python index baseline ({python:.3f} s)", zorder=2)

    # Rust line
    ax.plot(threads, times, color=RUST_COLOR, marker="o", linewidth=1.8,
            markersize=6, label="Rust (Rayon)", zorder=3)

    # Annotate optimal point
    ax.annotate(
        f"optimal: t={threads[opt_idx]}\n({times[opt_idx]:.3f} s)",
        xy=(threads[opt_idx], times[opt_idx]),
        xytext=(threads[opt_idx] + 6, times[opt_idx] + 0.07),
        fontsize=9, color=OPT_COLOR,
        arrowprops=dict(arrowstyle="->", color=OPT_COLOR, lw=1.2),
    )
    # Annotate degradation arrow
    ax.annotate("", xy=(64, times[-1]), xytext=(4, times[opt_idx]),
                arrowprops=dict(arrowstyle="-|>", color="gray",
                                lw=1.0, linestyle="dotted"))

    ax.set_xscale("log", base=2)
    ax.set_xticks(threads)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Number of Rayon threads")
    ax.set_ylabel("Query execution time (s)")
    ax.set_title("Thread scaling — dev\\_small\n(200 queries, 50k histograms)")
    ax.legend(loc="upper right")
    ax.set_ylim(0, python * 1.25)

    # Shade "over-threading" region
    ax.axvspan(8, 72, alpha=0.06, color="gray", label="_nolegend_")
    ax.text(16, python * 1.12, "coordination overhead\ndominates", fontsize=8,
            color="gray", ha="center")

    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"ablation_dev_small_threads.{ext}",
                    dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: ablation_dev_small_threads.pdf/.png")


# ── Figure 2: eval_medium ─────────────────────────────────────────────────────
def plot_eval_medium():
    threads = eval_medium["threads"]
    times   = eval_medium["times"]
    python  = eval_medium["python"]

    fig, ax = plt.subplots(figsize=(5.5, 3.8))

    # Python baseline
    ax.axhline(python, color=PYTHON_COLOR, linestyle="--", linewidth=1.4,
               label=f"Python index baseline ({python:.0f} s)", zorder=2)

    # Rust line
    ax.plot(threads, times, color=RUST_COLOR, marker="o", linewidth=1.8,
            markersize=6, label="Rust (Rayon)", zorder=3)

    # Ideal linear-scaling reference (dashed, lighter)
    ideal = [times[0] / t for t in threads]
    ax.plot(threads, ideal, color=RUST_COLOR, linestyle=":", linewidth=1.2,
            alpha=0.45, label="Ideal linear scaling (reference)")

    # Annotate flat region
    mean_t = float(np.mean(times))
    ax.annotate(
        f"flat: {min(times):.0f}–{max(times):.0f} s\n(memory-bandwidth bound)",
        xy=(8, mean_t),
        xytext=(12, mean_t - 120),
        fontsize=9, color="gray",
        arrowprops=dict(arrowstyle="->", color="gray", lw=1.0),
    )

    ax.set_xscale("log", base=2)
    ax.set_xticks(threads)
    ax.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax.set_xlabel("Number of Rayon threads")
    ax.set_ylabel("Query execution time (s)")
    ax.set_title("Thread scaling — eval\\_medium\n(10 000 queries, 200k histograms, 494 MB index)")
    ax.legend(loc="upper right")
    ax.set_ylim(0, python * 1.15)

    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"ablation_eval_medium_threads.{ext}",
                    dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: ablation_eval_medium_threads.pdf/.png")


# ── Figure 3: Combined panel (thesis-ready) ──────────────────────────────────
def plot_combined():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10.5, 4.0))

    # ── left: dev_small ──
    threads = dev_small["threads"]
    times   = dev_small["times"]
    python  = dev_small["python"]
    opt_idx = int(np.argmin(times))

    ax1.axhline(python, color=PYTHON_COLOR, linestyle="--", linewidth=1.4,
                label=f"Python ({python:.3f} s)")
    ax1.plot(threads, times, color=RUST_COLOR, marker="o", linewidth=1.8,
             markersize=6, label="Rust (Rayon)")
    ax1.annotate(
        f"t={threads[opt_idx]}\n({times[opt_idx]:.3f} s)",
        xy=(threads[opt_idx], times[opt_idx]),
        xytext=(threads[opt_idx] + 5, times[opt_idx] + 0.06),
        fontsize=8.5, color=OPT_COLOR,
        arrowprops=dict(arrowstyle="->", color=OPT_COLOR, lw=1.1),
    )
    ax1.axvspan(8, 72, alpha=0.06, color="gray")
    ax1.text(20, python * 1.10, "overhead\ndominates", fontsize=8,
             color="gray", ha="center")
    ax1.set_xscale("log", base=2)
    ax1.set_xticks(threads)
    ax1.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax1.set_xlabel("Rayon threads")
    ax1.set_ylabel("Query execution time (s)")
    ax1.set_title("(a) dev\\_small — compute-bound\n(200 queries, 50k histograms)")
    ax1.legend(loc="upper right", fontsize=9)
    ax1.set_ylim(0, python * 1.28)
    ax1.spines["top"].set_visible(False)
    ax1.spines["right"].set_visible(False)
    ax1.grid(True, alpha=0.3, linestyle="--")

    # ── right: eval_medium ──
    threads = eval_medium["threads"]
    times   = eval_medium["times"]
    python  = eval_medium["python"]
    ideal   = [times[0] / t for t in threads]
    mean_t  = float(np.mean(times))

    ax2.axhline(python, color=PYTHON_COLOR, linestyle="--", linewidth=1.4,
                label=f"Python ({python:.0f} s)")
    ax2.plot(threads, times, color=RUST_COLOR, marker="o", linewidth=1.8,
             markersize=6, label="Rust (Rayon)")
    ax2.plot(threads, ideal, color=RUST_COLOR, linestyle=":", linewidth=1.2,
             alpha=0.4, label="Ideal linear scaling")
    ax2.annotate(
        f"flat: memory-bandwidth\nbound (~{mean_t:.0f} s all threads)",
        xy=(8, mean_t),
        xytext=(14, mean_t - 150),
        fontsize=8.5, color="gray",
        arrowprops=dict(arrowstyle="->", color="gray", lw=1.0),
    )
    ax2.set_xscale("log", base=2)
    ax2.set_xticks(threads)
    ax2.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax2.set_xlabel("Rayon threads")
    ax2.set_ylabel("Query execution time (s)")
    ax2.set_title("(b) eval\\_medium — memory-bandwidth-bound\n(10 000 queries, 200k histograms, 494 MB index)")
    ax2.legend(loc="upper right", fontsize=9)
    ax2.set_ylim(0, python * 1.15)
    ax2.spines["top"].set_visible(False)
    ax2.spines["right"].set_visible(False)
    ax2.grid(True, alpha=0.3, linestyle="--")

    fig.suptitle("Rayon Thread Scaling: Fainder Query Engine", fontsize=13, y=1.01)
    fig.tight_layout()
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"ablation_threads_combined.{ext}",
                    dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"Saved: ablation_threads_combined.pdf/.png")


if __name__ == "__main__":
    plot_dev_small()
    plot_eval_medium()
    plot_combined()
    print(f"\nAll figures in: {OUT.resolve()}")
