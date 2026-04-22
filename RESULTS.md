# Experiment Results

> All timings are **query phase only** — index is pre-built and loaded from disk.
> Python baseline uses `FAINDER_NO_RUST=1`; Rust uses the Rayon engine.

## 1. Baseline Comparison

### dev_small (200 queries, ~50k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| Exact scan | 56.230 | 122.2x slower |
| BinSort | 10.830 | 23.5x slower |
| PScan | 73.980 | 160.8x slower |
| Python rebinning | 0.837 | 1.8x slower |
| Python conversion | 0.900 | 2.0x slower |
| Rust rebinning | 0.460 | 1.0x slower |
| Rust conversion | 0.540 | 1.2x slower |

### eval_medium (10 000 queries, ~200k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| Python rebinning | 10.7 | 3.58x |
| Rust rebinning | 3.0 | 1.00x |

### eval_10gb (4 500 queries, 323k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| BinSort | 1681.0 | 32.26x |
| Python rebinning | 95.2 | 1.83x |
| Rust rebinning | 52.1 | 1.00x |

> Note: Exact scan and NDist were killed for eval_medium/eval_10gb (estimated days to complete).
> Paper values used as reference: GitTables full (5M hists) — exact scan 48,310s, BinSort 7,906s, Fainder 284s.

## 2. Python → Rust Speedup (Fainder query engine)

| Dataset | Histograms | Queries | Python reb. | Rust reb. | Speedup | Python conv. | Rust conv. | Speedup |
|---|---|---|---|---|---|---|---|---|
| dev_small | ~50k | 200 | 0.84s | 0.46s | **1.82x** | 0.90s | 0.54s | **1.67x** |
| eval_medium | ~200k | 10000 | 10.74s | 3.00s | **3.58x** | — | — | — |
| eval_10gb | 323k | 4500 | 95.20s | 52.10s | **1.83x** | — | — | — |

## 3. Parallelism Ablation — Thread Count Sweep

### dev_small (Python baseline: 0.84s)

| Threads | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| Time (s) | 0.72 | 0.66 | 0.46 | 0.66 | 0.71 | 0.66 | 0.74 |
| Speedup vs Python | 1.16x | 1.28x | 1.82x | 1.27x | 1.18x | 1.26x | 1.13x |

**Finding:** Peak at t=4 (0.460s = 1.82× over Python). Rust t=1 (0.719s) is SLOWER than Python (0.837s): Python numpy uses vectorized C searchsorted; Rust uses scalar partition_point. Parallelism compensates at t≥4.

### eval_medium (Python baseline: 10.74s)

| Threads | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| Time (s) | 24.05 | 13.07 | 7.22 | 4.91 | 3.00 | 4.04 | 3.61 |
| Speedup vs Python | 0.45x | 0.82x | 1.49x | 2.19x | 3.58x | 2.66x | 2.98x |

**Finding:** 8× parallel speedup from t=1 (24.05s) to t=16 (3.00s). Rust t=1 (24.05s) is 2.24× slower than Python (10.74s) — numpy vectorized C vs scalar Rust — parallelism compensates above t=4. NUMA regression at t=32 (4.04s): crossing NUMA socket boundary increases cross-socket memory latency. DRAM bandwidth saturates at t=16 (optimal).

## 4. Completed Ablation Summary

| Experiment | Key Finding | Figure |
|---|---|---|
| **SoA vs AoS layout** | ≤10% difference, inconsistent — memory layout not the bottleneck | fig7 |
| **tmpfs isolation** | Curves identical — bottleneck is DRAM latency, not I/O | fig6 |
| **NUMA pinning** | +6–14% at low thread count, fades at high — secondary effect | fig5 |
| **Cluster-level parallelism** | 34× more work units make no difference — latency-bound, not work-bound | fig9 |
| **Roofline (perf stat)** | IPC=0.94 at t=1 and t=64 — dependent cache-miss chain, ~270k DRAM/query | fig10 |
| **f16 precision** | 1.40× faster at t=16; 50% smaller index shifts data into LLC | fig11 |
| **Eytzinger (BFS) layout** | Wins at t=4 (1.13×); loses at t≥16 (50% footprint hurts bandwidth) | fig12 |
| **Columnar engine** | 2.49× at t=1 (cache reuse); row wins at t≥32 (task granularity) | fig13 |

## Figures

All figures in `analysis/figures/` (PDF for LaTeX, PNG for preview):

| File | Content |
|---|---|
| `fig1_baseline_dev_small` | Bar chart: all methods on dev_small (log scale) |
| `fig2_rust_vs_python_speedup` | Bars: Python→Rust engine speedup (suppress_results=True) |
| `fig3_thread_sweep` | Two-panel: thread scaling — dev_small (t=4 peak) + eval_medium (t=16 peak, NUMA at t=32) |
| `fig4_summary_heatmap` | Heatmap: all methods × all datasets |
| `fig5_numa_vs_unpinned` | NUMA pinning effect (hardware ablation) |
| `fig6_tmpfs_vs_disk` | tmpfs vs disk — confirms DRAM-bound not I/O-bound |
| `fig7_soa_vs_aos` | SoA vs AoS memory layout — marginal, inconsistent |
| `fig8_hardware_ablation_summary` | Combined hardware ablation summary |
| `fig9_cluster_par_ablation` | Cluster-par vs query-par — no difference |
| `fig10_roofline_perf` | Roofline: IPC=0.94, ~270k DRAM misses/query |
| `fig11_f16_comparison` | f16 vs f32: 1.40× speedup at t=16 |
| `fig12_eytzinger` | Eytzinger BFS vs SoA: wins at t=4, loses at high thread count |
| `fig13_columnar_vs_row` | Columnar vs row-centric: 2.49× at t=1, crossover at t≈20 |