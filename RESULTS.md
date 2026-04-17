# Experiment Results

> All timings are **query phase only** — index is pre-built and loaded from disk.
> Python baseline uses `FAINDER_NO_RUST=1`; Rust uses the Rayon engine.

## 1. Baseline Comparison

### dev_small (200 queries, ~50k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| Exact scan | 56.230 | 62.5x slower |
| BinSort | 10.830 | 12.0x slower |
| PScan | 73.980 | 82.2x slower |
| Python rebinning | 0.940 | 1.0x slower |
| Python conversion | 0.900 | 1.0x slower |
| Rust rebinning | 0.900 | 1.0x slower |
| Rust conversion | 0.540 | 0.6x slower |

### eval_medium (10 000 queries, ~200k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| Python rebinning | 714.8 | 1.24x |
| Python conversion | 710.3 | 1.24x |
| Rust rebinning | 574.6 | 1.00x |
| Rust conversion | 589.6 | 1.03x |

### eval_10gb (4 500 queries, 323k histograms)

| Method | Time (s) | vs. Rust rebinning |
|---|---|---|
| BinSort | 1681.0 | 25.20x |
| Python rebinning | 95.2 | 1.43x |
| Python conversion | 91.8 | 1.38x |
| Rust rebinning | 66.7 | 1.00x |
| Rust conversion | 85.8 | 1.29x |

> Note: Exact scan and NDist were killed for eval_medium/eval_10gb (estimated days to complete).
> Paper values used as reference: GitTables full (5M hists) — exact scan 48,310s, BinSort 7,906s, Fainder 284s.

## 2. Python → Rust Speedup (Fainder query engine)

| Dataset | Histograms | Queries | Python reb. | Rust reb. | Speedup | Python conv. | Rust conv. | Speedup |
|---|---|---|---|---|---|---|---|---|
| dev_small | ~50k | 200 | 0.94s | 0.90s | **1.04x** | 0.90s | 0.54s | **1.67x** |
| eval_medium | ~200k | 10000 | 714.80s | 574.60s | **1.24x** | 710.30s | 589.60s | **1.20x** |
| eval_10gb | 323k | 4500 | 95.20s | 66.70s | **1.43x** | 91.80s | 85.80s | **1.07x** |

## 3. Parallelism Ablation — Thread Count Sweep

### dev_small (Python baseline: 0.84s)

| Threads | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| Time (s) | 0.88 | 0.77 | 0.56 | 0.77 | 0.82 | 0.77 | 0.82 |
| Speedup vs Python | 0.95x | 1.09x | 1.50x | 1.09x | 1.02x | 1.09x | 1.02x |

**Finding:** Peak at t=4 (0.56s = 1.50x over Python). Coordination overhead exceeds computation beyond t=4 — workload is compute-bound but work units are too small.

### eval_medium (Python baseline: 732.10s)

| Threads | 1 | 2 | 4 | 8 | 16 | 32 | 64 |
|---|---|---|---|---|---|---|---|
| Time (s) | 565.50 | 545.60 | 553.30 | 576.40 | 570.30 | 578.20 | 556.50 |
| Speedup vs Python | 1.29x | 1.34x | 1.32x | 1.27x | 1.28x | 1.27x | 1.32x |

**Finding:** Flat curve — 546–578s regardless of thread count. Memory-bandwidth bound: all threads share the same DRAM bus, adding cores cannot help.

## 4. What Is Not Yet Measured (Planned)

| Experiment | What to build | Expected finding |
|---|---|---|
| **SoA vs AoS layout** | Cargo feature flag for Array-of-Structs SubIndex | SoA faster at large scale due to cache-line efficiency |
| **tmpfs isolation** | Copy index to `/dev/shm`, re-run thread sweep | Confirms DRAM-bound (not I/O-bound) |
| **NUMA pinning** | `numactl --membind=0 --cpunodebind=0` | Potential lift on multi-socket server |
| **partition_point vs binary_search** | Cargo feature swap | ~2–5% expected |
| **Roofline measurement** | `perf stat` cache miss counts | Places workload on hardware bandwidth curve |
| **Accuracy confirmation** | `compute-accuracy-metrics` Rust vs Python | Proves Rust produces identical results |

## Figures

All figures in `analysis/figures/` (PDF for LaTeX, PNG for preview):

| File | Content |
|---|---|
| `fig1_baseline_dev_small` | Bar chart: all methods on dev_small (log scale) |
| `fig2_rust_vs_python_speedup` | Grouped bars: Python→Rust speedup per dataset and index mode |
| `fig3_thread_sweep` | Two-panel: thread scaling dev_small (peak at t=4) + eval_medium (flat) |
| `fig4_summary_heatmap` | Heatmap: all methods × all datasets |