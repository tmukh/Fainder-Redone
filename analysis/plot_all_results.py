"""
Generates all publication-quality figures and RESULTS.md for the thesis.

Figures produced:
  fig1_baseline_comparison.pdf/png   — all methods, dev_small (log scale bar chart)
  fig2_rust_vs_python.pdf/png        — Python vs Rust speedup across datasets
  fig3_thread_sweep.pdf/png          — thread count ablation (two-panel)
  fig4_speedup_overview.pdf/png      — summary speedup table as heatmap

Output: analysis/figures/  +  RESULTS.md
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np
from pathlib import Path

OUT = Path("analysis/figures")
OUT.mkdir(parents=True, exist_ok=True)

# ── Colours ───────────────────────────────────────────────────────────────────
RUST_COL   = "#2166ac"   # blue
PYTHON_COL = "#d6604d"   # red/orange
GREEN      = "#4dac26"
GRAY       = "#888888"

BASELINE_COLORS = {
    "Exact scan":         "#b2182b",
    "BinSort":            "#ef8a62",
    "PScan":              "#fddbc7",
    "Python rebinning":   "#d6604d",
    "Python conversion":  "#f4a582",
    "Rust rebinning":     "#2166ac",
    "Rust conversion":    "#67a9cf",
}

plt.rcParams.update({
    "font.family":       "serif",
    "font.size":         11,
    "axes.titlesize":    12,
    "axes.labelsize":    11,
    "xtick.labelsize":   10,
    "ytick.labelsize":   10,
    "legend.fontsize":   9,
    "figure.dpi":        150,
    "axes.spines.top":   False,
    "axes.spines.right": False,
    "axes.grid":         True,
    "grid.alpha":        0.3,
    "grid.linestyle":    "--",
})

def save(fig, name):
    for ext in ("pdf", "png"):
        fig.savefig(OUT / f"{name}.{ext}", dpi=300, bbox_inches="tight")
    plt.close(fig)
    print(f"  Saved: {name}.pdf/.png")

# ═══════════════════════════════════════════════════════════════════════════════
# DATA
# ═══════════════════════════════════════════════════════════════════════════════

# All units: seconds

baseline = {
    "dev_small": {
        # 200 queries, ~50k histograms
        "Exact scan":        56.23,
        "BinSort":           10.83,
        "PScan":             73.98,
        "Python rebinning":   0.94,
        "Python conversion":  0.90,
        "Rust rebinning":     0.90,
        "Rust conversion":    0.54,
    },
    "eval_medium": {
        # 10 000 queries, ~200k histograms
        "Python rebinning":  714.8,
        "Python conversion": 710.3,
        "Rust rebinning":    574.6,
        "Rust conversion":   589.6,
    },
    "eval_10gb": {
        # 4 500 queries, 323k histograms
        "BinSort":          1681.0,
        "Python rebinning":   95.2,
        "Python conversion":  91.8,
        "Rust rebinning":     66.7,
        "Rust conversion":    85.8,
    },
}

thread_data = {
    "dev_small": {
        "threads": [1, 2, 4, 8, 16, 32, 64],
        "times":   [0.88, 0.77, 0.56, 0.77, 0.82, 0.77, 0.82],
        "python":  0.84,
    },
    "eval_medium": {
        "threads": [1, 2, 4, 8, 16, 32, 64],
        "times":   [565.5, 545.6, 553.3, 576.4, 570.3, 578.2, 556.5],
        "python":  732.1,
    },
}

DATASET_LABELS = {
    "dev_small":   "dev\\_small\n(200q, 50k hists)",
    "eval_medium": "eval\\_medium\n(10kq, 200k hists)",
    "eval_10gb":   "eval\\_10gb\n(4.5kq, 323k hists)",
}

# ═══════════════════════════════════════════════════════════════════════════════
# FIG 1 — Baseline comparison, dev_small (log-scale bar chart)
# ═══════════════════════════════════════════════════════════════════════════════
def fig1_baseline_dev_small():
    data = baseline["dev_small"]
    labels = list(data.keys())
    times  = list(data.values())
    colors = [BASELINE_COLORS[l] for l in labels]

    fig, ax = plt.subplots(figsize=(7, 4.2))
    bars = ax.barh(labels, times, color=colors, edgecolor="white", linewidth=0.5)

    # Value labels
    for bar, t in zip(bars, times):
        ax.text(t * 1.08, bar.get_y() + bar.get_height() / 2,
                f"{t:.2f}s", va="center", fontsize=8.5)

    ax.set_xscale("log")
    ax.set_xlabel("Query execution time (s, log scale)")
    ax.set_title("Baseline comparison — dev\\_small\n(200 queries, 50k histograms)")
    ax.invert_yaxis()
    ax.set_xlim(0.3, 500)
    ax.grid(True, axis="x", alpha=0.3, linestyle="--")
    ax.grid(False, axis="y")

    # Divider between "slow" and "Fainder"
    ax.axhline(2.5, color="gray", lw=0.8, linestyle=":")
    ax.text(0.35, 2.3, "index methods →", fontsize=8, color="gray")

    fig.tight_layout()
    save(fig, "fig1_baseline_dev_small")


# ═══════════════════════════════════════════════════════════════════════════════
# FIG 2 — Python vs Rust speedup across all 3 datasets × 2 modes
# ═══════════════════════════════════════════════════════════════════════════════
def fig2_rust_vs_python():
    datasets = ["dev_small", "eval_medium", "eval_10gb"]
    labels   = ["dev\\_small\n(200q, 50k)", "eval\\_medium\n(10kq, 200k)", "eval\\_10gb\n(4.5kq, 323k)"]

    speedup_reb = []
    speedup_con = []
    for ds in datasets:
        d = baseline[ds]
        speedup_reb.append(d["Python rebinning"] / d["Rust rebinning"])
        speedup_con.append(d["Python conversion"] / d["Rust conversion"])

    x = np.arange(len(datasets))
    w = 0.32

    fig, ax = plt.subplots(figsize=(7, 4.2))
    b1 = ax.bar(x - w/2, speedup_reb, w, label="Rebinning index", color=RUST_COL,   alpha=0.85)
    b2 = ax.bar(x + w/2, speedup_con, w, label="Conversion index", color="#67a9cf", alpha=0.85)

    for bar in list(b1) + list(b2):
        h = bar.get_height()
        ax.text(bar.get_x() + bar.get_width()/2, h + 0.01,
                f"{h:.2f}x", ha="center", va="bottom", fontsize=8.5)

    ax.axhline(1.0, color="gray", lw=1.0, linestyle="--", label="No speedup (1×)")
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_ylabel("Speedup (Python time / Rust time)")
    ax.set_title("Python → Rust speedup: Fainder query phase\n(same index, same queries — only execution engine differs)")
    ax.legend()
    ax.set_ylim(0, 2.0)
    ax.grid(True, axis="y", alpha=0.3, linestyle="--")
    ax.grid(False, axis="x")

    fig.tight_layout()
    save(fig, "fig2_rust_vs_python_speedup")


# ═══════════════════════════════════════════════════════════════════════════════
# FIG 3 — Thread sweep (two-panel, updated data)
# ═══════════════════════════════════════════════════════════════════════════════
def fig3_thread_sweep():
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4.2))

    # ── left: dev_small ──────────────────────────────────────────────────────
    d = thread_data["dev_small"]
    threads, times, python = d["threads"], d["times"], d["python"]
    opt_idx = int(np.argmin(times))

    ax1.axhline(python, color=PYTHON_COL, linestyle="--", lw=1.4,
                label=f"Python baseline ({python:.2f}s)")
    ax1.plot(threads, times, color=RUST_COL, marker="o", lw=1.8, ms=6,
             label="Rust (Rayon)")
    ax1.annotate(
        f"optimal: t={threads[opt_idx]}\n({times[opt_idx]:.2f}s)",
        xy=(threads[opt_idx], times[opt_idx]),
        xytext=(threads[opt_idx] + 5, times[opt_idx] + 0.08),
        fontsize=8.5, color=GREEN,
        arrowprops=dict(arrowstyle="->", color=GREEN, lw=1.1),
    )
    ax1.axvspan(8, 72, alpha=0.06, color="gray")
    ax1.text(18, python * 1.10, "coordination\noverhead", fontsize=8, color="gray", ha="center")
    ax1.set_xscale("log", base=2)
    ax1.set_xticks(threads)
    ax1.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax1.set_xlabel("Rayon threads")
    ax1.set_ylabel("Query execution time (s)")
    ax1.set_title("(a) dev\\_small — compute-bound\n(200 queries, 50k histograms)")
    ax1.legend(fontsize=9)
    ax1.set_ylim(0, python * 1.35)
    ax1.spines["top"].set_visible(False); ax1.spines["right"].set_visible(False)
    ax1.grid(True, alpha=0.3, linestyle="--")

    # ── right: eval_medium ───────────────────────────────────────────────────
    d = thread_data["eval_medium"]
    threads, times, python = d["threads"], d["times"], d["python"]
    ideal  = [times[0] / t for t in threads]
    mean_t = float(np.mean(times))

    ax2.axhline(python, color=PYTHON_COL, linestyle="--", lw=1.4,
                label=f"Python baseline ({python:.0f}s)")
    ax2.plot(threads, times, color=RUST_COL, marker="o", lw=1.8, ms=6,
             label="Rust (Rayon)")
    ax2.plot(threads, ideal, color=RUST_COL, linestyle=":", lw=1.2, alpha=0.4,
             label="Ideal linear scaling")
    ax2.annotate(
        f"flat: memory-bandwidth bound\n({min(times):.0f}–{max(times):.0f}s all threads)",
        xy=(8, mean_t), xytext=(14, mean_t - 160),
        fontsize=8.5, color="gray",
        arrowprops=dict(arrowstyle="->", color="gray", lw=1.0),
    )
    ax2.set_xscale("log", base=2)
    ax2.set_xticks(threads)
    ax2.get_xaxis().set_major_formatter(ticker.ScalarFormatter())
    ax2.set_xlabel("Rayon threads")
    ax2.set_ylabel("Query execution time (s)")
    ax2.set_title("(b) eval\\_medium — memory-bandwidth-bound\n(10 000 queries, 200k histograms)")
    ax2.legend(fontsize=9)
    ax2.set_ylim(0, python * 1.18)
    ax2.spines["top"].set_visible(False); ax2.spines["right"].set_visible(False)
    ax2.grid(True, alpha=0.3, linestyle="--")

    fig.suptitle("Rayon Thread Scaling: Fainder Query Engine", fontsize=13, y=1.01)
    fig.tight_layout()
    save(fig, "fig3_thread_sweep")


# ═══════════════════════════════════════════════════════════════════════════════
# FIG 4 — All-methods heatmap / summary table across datasets
# ═══════════════════════════════════════════════════════════════════════════════
def fig4_summary_heatmap():
    methods  = ["Exact scan", "BinSort", "PScan",
                "Python rebinning", "Python conversion",
                "Rust rebinning",   "Rust conversion"]
    datasets = ["dev_small", "eval_medium", "eval_10gb"]
    d_labels = ["dev\\_small\n(50k hists)", "eval\\_medium\n(200k hists)", "eval\\_10gb\n(323k hists)"]

    # Build matrix (NaN = not measured / killed)
    matrix = np.full((len(methods), len(datasets)), np.nan)
    for j, ds in enumerate(datasets):
        d = baseline[ds]
        for i, m in enumerate(methods):
            if m in d:
                matrix[i, j] = d[m]

    # Log-scale for display
    log_matrix = np.where(np.isnan(matrix), np.nan, np.log10(matrix))

    fig, ax = plt.subplots(figsize=(7, 5.5))
    im = ax.imshow(log_matrix, cmap="RdYlGn_r", aspect="auto",
                   vmin=np.nanmin(log_matrix), vmax=np.nanmax(log_matrix))

    ax.set_xticks(range(len(datasets)))
    ax.set_xticklabels(d_labels, fontsize=10)
    ax.set_yticks(range(len(methods)))
    ax.set_yticklabels(methods, fontsize=10)

    # Annotate cells
    for i in range(len(methods)):
        for j in range(len(datasets)):
            v = matrix[i, j]
            if not np.isnan(v):
                txt = f"{v:.2f}s" if v < 100 else f"{v:.0f}s"
                ax.text(j, i, txt, ha="center", va="center", fontsize=8.5,
                        color="white" if log_matrix[i, j] > 2.5 else "black")
            else:
                ax.text(j, i, "—", ha="center", va="center", fontsize=10, color="#aaaaaa")

    cbar = fig.colorbar(im, ax=ax, fraction=0.03, pad=0.02)
    cbar.set_label("log₁₀(time in seconds)", fontsize=9)
    cbar.set_ticks([0, 1, 2, 3, 4])
    cbar.set_ticklabels(["1s", "10s", "100s", "1000s", "10000s"])

    ax.set_title("Query execution time — all methods × datasets\n(green = fast, red = slow)", pad=12)

    # Divider between slow baselines and Fainder
    ax.axhline(2.5, color="white", lw=1.5)

    fig.tight_layout()
    save(fig, "fig4_summary_heatmap")


# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS.md
# ═══════════════════════════════════════════════════════════════════════════════
def write_results_md():
    lines = []
    a = lines.append

    a("# Experiment Results")
    a("")
    a("> All timings are **query phase only** — index is pre-built and loaded from disk.")
    a("> Python baseline uses `FAINDER_NO_RUST=1`; Rust uses the Rayon engine.")
    a("")

    a("## 1. Baseline Comparison")
    a("")
    a("### dev_small (200 queries, ~50k histograms)")
    a("")
    a("| Method | Time (s) | vs. Rust rebinning |")
    a("|---|---|---|")
    ref = baseline["dev_small"]["Rust rebinning"]
    for m, t in baseline["dev_small"].items():
        a(f"| {m} | {t:.3f} | {t/ref:.1f}x slower |")
    a("")

    a("### eval_medium (10 000 queries, ~200k histograms)")
    a("")
    a("| Method | Time (s) | vs. Rust rebinning |")
    a("|---|---|---|")
    ref = baseline["eval_medium"]["Rust rebinning"]
    for m, t in baseline["eval_medium"].items():
        a(f"| {m} | {t:.1f} | {t/ref:.2f}x |")
    a("")

    a("### eval_10gb (4 500 queries, 323k histograms)")
    a("")
    a("| Method | Time (s) | vs. Rust rebinning |")
    a("|---|---|---|")
    ref = baseline["eval_10gb"]["Rust rebinning"]
    for m, t in baseline["eval_10gb"].items():
        a(f"| {m} | {t:.1f} | {t/ref:.2f}x |")
    a("")
    a("> Note: Exact scan and NDist were killed for eval_medium/eval_10gb (estimated days to complete).")
    a("> Paper values used as reference: GitTables full (5M hists) — exact scan 48,310s, BinSort 7,906s, Fainder 284s.")
    a("")

    a("## 2. Python → Rust Speedup (Fainder query engine)")
    a("")
    a("| Dataset | Histograms | Queries | Python reb. | Rust reb. | Speedup | Python conv. | Rust conv. | Speedup |")
    a("|---|---|---|---|---|---|---|---|---|")
    meta = {
        "dev_small":   ("~50k",  200),
        "eval_medium": ("~200k", 10000),
        "eval_10gb":   ("323k",  4500),
    }
    for ds in ["dev_small", "eval_medium", "eval_10gb"]:
        d = baseline[ds]
        hists, queries = meta[ds]
        pr = d["Python rebinning"]; rr = d["Rust rebinning"]
        pc = d["Python conversion"]; rc = d["Rust conversion"]
        a(f"| {ds} | {hists} | {queries} | {pr:.2f}s | {rr:.2f}s | **{pr/rr:.2f}x** | {pc:.2f}s | {rc:.2f}s | **{pc/rc:.2f}x** |")
    a("")

    a("## 3. Parallelism Ablation — Thread Count Sweep")
    a("")
    for ds in ["dev_small", "eval_medium"]:
        d = thread_data[ds]
        threads, times, python = d["threads"], d["times"], d["python"]
        opt_t = threads[int(np.argmin(times))]
        opt_v = min(times)
        a(f"### {ds} (Python baseline: {python:.2f}s)")
        a("")
        a("| Threads | 1 | 2 | 4 | 8 | 16 | 32 | 64 |")
        a("|---|---|---|---|---|---|---|---|")
        row = " | ".join(f"{t:.2f}" for t in times)
        a(f"| Time (s) | {row} |")
        a(f"| Speedup vs Python | " + " | ".join(f"{python/t:.2f}x" for t in times) + " |")
        a("")
        if ds == "dev_small":
            a(f"**Finding:** Peak at t={opt_t} ({opt_v:.2f}s = {python/opt_v:.2f}x over Python). "
              f"Coordination overhead exceeds computation beyond t=4 — workload is compute-bound but work units are too small.")
        else:
            a(f"**Finding:** Flat curve — {min(times):.0f}–{max(times):.0f}s regardless of thread count. "
              f"Memory-bandwidth bound: all threads share the same DRAM bus, adding cores cannot help.")
        a("")

    a("## 4. What Is Not Yet Measured (Planned)")
    a("")
    a("| Experiment | What to build | Expected finding |")
    a("|---|---|---|")
    a("| **SoA vs AoS layout** | Cargo feature flag for Array-of-Structs SubIndex | SoA faster at large scale due to cache-line efficiency |")
    a("| **tmpfs isolation** | Copy index to `/dev/shm`, re-run thread sweep | Confirms DRAM-bound (not I/O-bound) |")
    a("| **NUMA pinning** | `numactl --membind=0 --cpunodebind=0` | Potential lift on multi-socket server |")
    a("| **partition_point vs binary_search** | Cargo feature swap | ~2–5% expected |")
    a("| **Roofline measurement** | `perf stat` cache miss counts | Places workload on hardware bandwidth curve |")
    a("| **Accuracy confirmation** | `compute-accuracy-metrics` Rust vs Python | Proves Rust produces identical results |")
    a("")
    a("## Figures")
    a("")
    a("All figures in `analysis/figures/` (PDF for LaTeX, PNG for preview):")
    a("")
    a("| File | Content |")
    a("|---|---|")
    a("| `fig1_baseline_dev_small` | Bar chart: all methods on dev_small (log scale) |")
    a("| `fig2_rust_vs_python_speedup` | Grouped bars: Python→Rust speedup per dataset and index mode |")
    a("| `fig3_thread_sweep` | Two-panel: thread scaling dev_small (peak at t=4) + eval_medium (flat) |")
    a("| `fig4_summary_heatmap` | Heatmap: all methods × all datasets |")

    Path("RESULTS.md").write_text("\n".join(lines))
    print("  Saved: RESULTS.md")


# ═══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print("Generating figures...")
    fig1_baseline_dev_small()
    fig2_rust_vs_python()
    fig3_thread_sweep()
    fig4_summary_heatmap()
    write_results_md()
    print(f"\nAll figures → {OUT.resolve()}")
    print("Results doc → RESULTS.md")
