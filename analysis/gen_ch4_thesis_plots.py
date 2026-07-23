"""Generate Ch4 thesis plots directly from logs/bench.db.

All numbers verified against bench.db per CLAUDE.md data-integrity rule.
Merges lennart_c256_56gb_default_finet (5-10 rep fine-t upgrade) with the
main sweep for the four-ceiling curve; other plots use main_* since there
is no lennart re-run covering the required (label, thread count) cells.

Outputs to Thesis tex/img/gen/. Re-run any time bench.db is refreshed:
    python analysis/gen_ch4_thesis_plots.py
"""
import sqlite3
import statistics
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import numpy as np

plt.rcParams.update({
    "font.family": "serif",
    "font.size": 10,
    "axes.labelsize": 10,
    "axes.titlesize": 11,
    "xtick.labelsize": 9,
    "ytick.labelsize": 9,
    "legend.fontsize": 9,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "grid.linewidth": 0.5,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "figure.dpi": 100,
    "savefig.bbox": "tight",
    "savefig.pad_inches": 0.05,
})

OUT = Path("Thesis tex/img/gen")
OUT.mkdir(parents=True, exist_ok=True)
C = sqlite3.connect("logs/bench.db")


def stats_for(label):
    """Return {threads: (median_wall, ci95, n_reps)} for a bench.db label.

    Uses median (matches the campaign methodology in §3.3.2). For the CI
    half-width we trim the min and max of each cell before computing stdev,
    so that a single cold-start / thermal outlier does not blow up the
    interval — matching §3.3.3's discard-first-rep discipline symmetrically.
    Cells with fewer than 3 reps report zero CI.
    """
    rows = C.execute(
        "SELECT threads, wall_s FROM runs WHERE label=? AND wall_s IS NOT NULL",
        (label,),
    ).fetchall()
    by_t = {}
    for t, w in rows:
        by_t.setdefault(t, []).append(w)
    out = {}
    for t, ws in by_t.items():
        m = statistics.median(ws)
        if len(ws) >= 3:
            trimmed = sorted(ws)[1:-1]
            sd = statistics.stdev(trimmed) if len(trimmed) > 1 else 0.0
            ci95 = 1.96 * sd / len(trimmed) ** 0.5
        else:
            ci95 = 0.0
        out[t] = (m, ci95, len(ws))
    return out


# =====================================================================
# 1. Four-ceiling wall-time curve on c256_56gb
#    Merges main_56gb_default_supp (t=1,8,16,32,64,96 @ 5 reps) with
#    lennart_c256_56gb_default_finet (t=8-48 dense @ 5-10 reps).
#    Where both cover a thread count, lennart wins (higher reps).
# =====================================================================
main = stats_for("main_56gb_default_supp")
lennart = stats_for("lennart_c256_56gb_default_finet")
merged = dict(main)
for t, v in lennart.items():
    merged[t] = v

ts_all = sorted(merged.keys())
walls = [merged[t][0] for t in ts_all]

main_ts = [t for t in ts_all if t not in lennart]
lennart_ts = [t for t in ts_all if t in lennart]

fig, ax = plt.subplots(figsize=(6.0, 3.8))
ax.plot(ts_all, walls, color="#1f77b4", linewidth=1.4, zorder=1)
ax.errorbar(
    main_ts, [merged[t][0] for t in main_ts],
    yerr=[merged[t][1] for t in main_ts],
    fmt="o", markersize=6, color="#1f77b4", capsize=3, zorder=2,
    label="main sweep (5 reps)",
)
ax.errorbar(
    lennart_ts, [merged[t][0] for t in lennart_ts],
    yerr=[merged[t][1] for t in lennart_ts],
    fmt="s", markersize=5, color="#d62728", capsize=3, zorder=3,
    label="fine-$t$ upgrade (5-10 reps)",
)

ax.set_xscale("log", base=2)
ax.set_yscale("log")
ax.set_xticks([1, 2, 4, 8, 16, 32, 48, 64, 96])
ax.set_xticklabels(["1", "2", "4", "8", "16", "32", "48", "64", "96"])
ax.set_xlabel(r"threads $t$")
ax.set_ylabel("search-phase wall time (s)")

ax.axvspan(0.9, 8, alpha=0.08, color="#e41a1c", zorder=0)
ax.axvspan(8, 32, alpha=0.08, color="#377eb8", zorder=0)
ax.axvspan(32, 48, alpha=0.08, color="#4daf4a", zorder=0)
ax.axvspan(48, 100, alpha=0.08, color="#984ea3", zorder=0)

ymax = max(walls) * 1.5
ax.text(3, ymax, "(i)\nL1 latency", ha="center", va="top", fontsize=8, color="#7a1a1a")
ax.text(16, ymax, "(ii)\nL3 capacity", ha="center", va="top", fontsize=8, color="#1a3d7a")
ax.text(39, ymax, "(iii)\nmem traffic", ha="center", va="top", fontsize=8, color="#1a5a1a")
ax.text(70, ymax, "(iv)\nUPI", ha="center", va="top", fontsize=8, color="#5a1a7a")

ax.set_title("Search-phase wall time vs. thread count on c256_56gb", pad=6)
ax.legend(loc="lower left")
plt.savefig(OUT / "ch4_four_ceilings.pdf")
plt.close()
print("wrote", OUT / "ch4_four_ceilings.pdf")


# =====================================================================
# 2. AoS flip pattern on c256_56gb (ceiling ii -> iii handoff)
#    No lennart re-run of AoS exists -> uses main_56gb_aos_supp (5 reps).
# =====================================================================
d = stats_for("main_56gb_default_supp")
a = stats_for("main_56gb_aos_supp")
common = sorted(set(d) & set(a))
deltas = [(a[t][0] - d[t][0]) / d[t][0] * 100 for t in common]
errs = []
for t in common:
    rel_ci_a = a[t][1] / a[t][0] if a[t][0] > 0 else 0
    rel_ci_d = d[t][1] / d[t][0] if d[t][0] > 0 else 0
    errs.append((rel_ci_a**2 + rel_ci_d**2) ** 0.5 * 100)

fig, ax = plt.subplots(figsize=(5.8, 3.2))
colors = ["#d62728" if x > 0 else "#2ca02c" for x in deltas]
ax.bar(range(len(common)), deltas, color=colors, alpha=0.85,
       edgecolor="black", linewidth=0.5)
ax.errorbar(range(len(common)), deltas, yerr=errs, fmt="none",
            ecolor="black", capsize=3, linewidth=0.8)

ax.axhline(0, color="black", linewidth=0.7)
ax.set_xticks(range(len(common)))
ax.set_xticklabels([str(t) for t in common])
ax.set_xlabel(r"threads $t$")
ax.set_ylabel(r"AoS vs. default wall delta (%)")
ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=1))

for i, (v, e) in enumerate(zip(deltas, errs)):
    yshift = e + 1 if v > 0 else -(e + 3)
    ax.text(i, v + yshift, f"{v:+.1f}", ha="center",
            va="bottom" if v > 0 else "top", fontsize=8)

ax.set_title(r"AoS layout: peaks $+16.5\%$ at $t=8$, sign-flips at $t\geq 64$", pad=6)
plt.savefig(OUT / "ch4_aos_flip.pdf")
plt.close()
print("wrote", OUT / "ch4_aos_flip.pdf")


# =====================================================================
# 3. Fine-t f16 vs default on c256_56gb (Ceiling ii standalone verdict)
#    Uses lennart_c256_56gb_f16 (10 reps) vs
#    lennart_c256_56gb_default_finet + main_56gb_default_supp merged.
#    CIs are the pooled Student-t half-width from §3.3.5 (dof-correct).
# =====================================================================
FINE_T = [8, 12, 14, 16, 18, 20, 24, 28, 32, 48]
TCRIT = {  # pooled Student t 0.975 quantile at various dof = n_a + n_b - 2
    8: 2.306, 13: 2.160, 18: 2.101,  # n=(5,5), (5,10)/(10,5), (10,10)
}

def _walls(labels_list, t):
    ph = ",".join(["?"] * len(labels_list))
    return [r[0] for r in C.execute(
        f"SELECT wall_s FROM runs WHERE label IN ({ph}) AND threads=? AND wall_s IS NOT NULL",
        (*labels_list, t)).fetchall()]

def _mean_ci(base, abl):
    if len(base) < 2 or len(abl) < 2:
        return None, None
    m_a = statistics.mean(base); m_b = statistics.mean(abl)
    sd_a = statistics.stdev(base); sd_b = statistics.stdev(abl)
    se = (sd_a**2 / len(base) + sd_b**2 / len(abl)) ** 0.5
    dof = len(base) + len(abl) - 2
    tcrit = TCRIT.get(dof, 2.101)
    delta_pct = 100 * (m_b - m_a) / m_a
    ci_pct = 100 * tcrit * se / m_a
    return delta_pct, ci_pct

DEF_LABELS = ["lennart_c256_56gb_default_finet", "main_56gb_default_supp"]
F16_LABELS = ["lennart_c256_56gb_f16"]
ts, deltas, cis = [], [], []
for t in FINE_T:
    base = _walls(DEF_LABELS, t)
    ablr = _walls(F16_LABELS, t)
    d, c_ = _mean_ci(base, ablr)
    if d is None:
        continue
    ts.append(t); deltas.append(d); cis.append(c_)

fig, ax = plt.subplots(figsize=(6.0, 3.4))
colors = ["#d62728" if d > 0 else "#2ca02c" for d in deltas]
# Highlight statistically significant cells (|delta| > CI) with saturated fill;
# non-significant with pale fill.
alphas = [0.9 if abs(d) > c_ else 0.35 for d, c_ in zip(deltas, cis)]
for i, (d, c_, col, a) in enumerate(zip(deltas, cis, colors, alphas)):
    ax.bar(i, d, color=col, alpha=a, edgecolor="black", linewidth=0.5)
ax.errorbar(range(len(ts)), deltas, yerr=cis, fmt="none",
            ecolor="black", capsize=3, linewidth=0.8)
ax.axhline(0, color="black", linewidth=0.7)
ax.set_xticks(range(len(ts)))
ax.set_xticklabels([str(t) for t in ts])
ax.set_xlabel(r"threads $t$")
ax.set_ylabel(r"f16 vs. default wall delta (%)")
ax.yaxis.set_major_formatter(mtick.PercentFormatter(decimals=1))
for i, (d, c_) in enumerate(zip(deltas, cis)):
    yshift = c_ + 0.6 if d > 0 else -(c_ + 1.4)
    ax.text(i, d + yshift, f"{d:+.1f}", ha="center",
            va="bottom" if d > 0 else "top", fontsize=8)
ax.set_title(r"f16 standalone on c256_56gb: two significant losses,"
             " otherwise null", pad=6)
plt.savefig(OUT / "ch4_f16_finet.pdf")
plt.close()
print("wrote", OUT / "ch4_f16_finet.pdf")


# =====================================================================
# 4. Search-phase and end-to-end speedup vs Python across scales, at t=16.
#    Both bands are apples-to-apples: suppress-vs-suppress and
#    with-results-vs-with-results. See §4.15/§4.15.1 for the mechanism
#    decomposition (result-materialisation dominates end-to-end).
#
#    Label conventions (bench.db):
#      Python suppress:      main_{10,30}gb_python_supp
#                            main_56gb_python_supp        (full 10K, preferred)
#                            main_56gb_python_supp_subsample1k  (fallback, ×10)
#      Python with-results:  main_{10,30}gb_python_with
#                            main_56gb_python_with_subsample1k  (×10)
#      Rust bestofsuite:     main_{10,30,56}gb_bestofsuite_supp
#                            main_{10,30,56}gb_bestofsuite_with
# =====================================================================

def _py_wall(dataset, mode, t):
    """Get Python wall for (dataset, mode, t). Prefers full-10K label when
    available; falls back to subsample1k * 10 for c256_56gb."""
    assert mode in {"supp", "with"}
    full_label = f"main_{dataset}_python_{mode}"
    subs_label = f"main_{dataset}_python_{mode}_subsample1k"
    full = stats_for(full_label).get(t, (None, None, 0))[0]
    if full is not None:
        return full
    subs = stats_for(subs_label).get(t, (None, None, 0))[0]
    return subs * 10 if subs is not None else None


T_TARGET = 16
DATASETS = [("10gb", "c256\\_10gb"), ("30gb", "c256\\_30gb"), ("56gb", "c256\\_56gb")]

supp_speedups, with_speedups = [], []
for tag, _ in DATASETS:
    py_supp = _py_wall(tag, "supp", T_TARGET)
    py_with = _py_wall(tag, "with", T_TARGET)
    rust_supp = stats_for(f"main_{tag}_bestofsuite_supp").get(T_TARGET, (None,))[0]
    rust_with = stats_for(f"main_{tag}_bestofsuite_with").get(T_TARGET, (None,))[0]
    supp_speedups.append(py_supp / rust_supp if py_supp and rust_supp else 0)
    with_speedups.append(py_with / rust_with if py_with and rust_with else 0)

fig, ax = plt.subplots(figsize=(6.2, 3.4))
x_pos = np.arange(len(DATASETS))
bar_width = 0.38

# Two bar groups per dataset: search-phase (suppress) vs end-to-end (with-results).
# Log scale on y because 1.34x and 600x can't share a linear axis.
ax.bar(x_pos - bar_width / 2, supp_speedups, bar_width,
       color="#4d90d9", edgecolor="black", linewidth=0.5,
       label="search-phase (suppress on both engines)")
ax.bar(x_pos + bar_width / 2, with_speedups, bar_width,
       color="#1f4e79", edgecolor="black", linewidth=0.5,
       label="end-to-end (with-results on both engines)")

for xp, sp in zip(x_pos - bar_width / 2, supp_speedups):
    if sp > 0:
        label = f"{sp:.1f}" + r"$\times$" if sp < 10 else f"{sp:.0f}" + r"$\times$"
        ax.text(xp, sp * 1.15, label, ha="center", fontsize=9)
for xp, sp in zip(x_pos + bar_width / 2, with_speedups):
    if sp > 0:
        ax.text(xp, sp * 1.15, f"{sp:.0f}" + r"$\times$", ha="center", fontsize=9)

ax.set_yscale("log")
ax.set_xticks(x_pos)
ax.set_xticklabels([disp for _, disp in DATASETS])
ax.set_xlabel("workload")
ax.set_ylabel(r"Rust bestofsuite speedup over Python ($\times$, log)")
ax.legend(loc="upper right", fontsize=8)
ax.set_title(r"Rust vs. Python at $t{=}16$", pad=6)
plt.savefig(OUT / "ch4_e2e_speedup.pdf")
plt.close()
print("wrote", OUT / "ch4_e2e_speedup.pdf")
