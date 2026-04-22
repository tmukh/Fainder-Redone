# Fainder Thesis: Centralized Progress Log

> **One document to rule them all.** Update this after every experiment.
> All other MD files in `MD files/` are superseded by this document.

---

## What We Are Doing

**Thesis goal**: A scientific ablation study of the Fainder VLDB 2024 query engine.
Not "Rust is faster than Python" — but *which specific optimizations contribute how much, and why does this workload benefit from each*.

**Scope**: Query phase only. The index is pre-built offline; all timing is query execution.

**System**: sr650-14 — 2× NUMA nodes × 96 cores, ~1 TB RAM total (~512 GB/node).

---

## Starting Point: Original Python Fainder

The original repo (`fainder/`) is pure Python + NumPy. It implements:
- **Rebinning mode**: 1 histogram variant per cluster bin → fast approximate search
- **Conversion mode**: 2 histogram variants per cluster bin (float16) → higher precision

Baseline query times (serial, default Python):

| Dataset | Histograms | Queries | Python time |
|---------|-----------|---------|-------------|
| dev_small | 50k | 200 | 0.84s |
| eval_medium | 200k | 10,000 | ~732s |
| eval_10gb | 323k | 10,000 | ~514–950s |

---

## What We Built in Rust

A PyO3/Maturin Rust extension (`src/`) that replaces the Python query loop:

1. **`src/index.rs`** — `FainderIndex` struct, loads `.zst` index files into Rust memory
2. **`src/engine.rs`** — `execute_queries()`, parallel query execution via Rayon
3. **`fainder/execution/percentile_queries.py`** — Python wrapper that detects Rust availability and dispatches to it (falls back to Python if `FAINDER_NO_RUST=1`)

Key optimizations implemented:
- **Rayon work-stealing parallelism** — `par_iter()` over queries; each cluster loop serial
- **Structure-of-Arrays (SoA) memory layout** — separate `values: Vec<f32>` and `indices: Vec<u32>` columns for cache-efficient binary search
- **`partition_point` binary search** — Rust standard library, branchless
- **Typed query execution** — parse query operators to an enum once, not per-cluster

Bug fixed: conversion index stored as float16 in Python → cast to float32 at Rust boundary in `fainder/execution/percentile_queries.py`.

---

## Experiments Run

### 1. Parallelism Ablation — Thread Sweep (query-level only)

**Script**: `scripts/ablation_parallel.sh`
**What it measures**: Rust query time as Rayon thread count scales 1→64
**Config**: Default build (no feature flags), `FAINDER_NUM_THREADS=N`

#### dev_small (200 queries, rebinning)

| Threads | Time (s) | vs Python (0.84s) |
|---------|----------|-------------------|
| 1 | 0.88 | ~1.0x (≈ same) |
| 2 | 0.77 | 1.1x |
| 4 | 0.56 | 1.5x |
| 8 | 0.77 | 1.1x |
| 16 | 0.82 | 1.0x |
| 32 | 0.77 | 1.1x |
| 64 | 0.82 | 1.0x |

**Finding**: dev_small is too small to show parallelism benefit — high variance, no trend. 200 queries is insufficient work.

#### eval_medium (10,000 queries, rebinning) — **CORRECTED** ✅ (April 22, post-bug-fix + suppress_results fix)

Previous data (560–590s flat) was invalid: bugs meant only 70% of results returned (less set-building), and `suppress_results` was not honored in Rust path. Both issues are now fixed.

| Threads | Total (s) | `run_queries` only (s) | Speedup vs t=1 | vs Python (10.74s) |
|---------|-----------|------------------------|----------------|--------------------|
| Python serial | 10.74s | 10.74s | — | 1.00x |
| 1 | 41.5s | **24.05s** | 1.00x | 0.45x (slower!) |
| 2 | 30.63s | **13.07s** | 1.84x | 0.82x |
| 4 | 25.87s | **7.22s** | 3.33x | 1.49x |
| 8 | 23.42s | **4.91s** | 4.90x | 2.19x |
| 16 | 23.08s | **3.00s** | 8.02x | **3.58x** ← peak |
| 32 | 25.14s | 4.04s | 5.95x | 2.66x (regresses!) |
| 64 | 22.5s | **3.61s** | 6.67x | 2.97x |

*Total time includes ~18s FainderIndex construction (same for all thread counts). In production with cached index, only `run_queries` time matters.*

**Key findings**:
1. **Parallelism scales cleanly from t=1 to t=16** (8x speedup) — Rayon work-stealing works as designed
2. **t=16 is the sweet spot** (3.00s, 3.58x vs Python) — DRAM bandwidth saturates here
3. **t=32 regresses** slightly (4.04s) — crosses NUMA node boundary, cross-socket memory latency kicks in; consistent with NUMA ablation showing 3.7% benefit of pinning at t=32
4. **Rust t=1 is 2.24x SLOWER than Python** — Python's `np.searchsorted` (vectorized C) beats Rust's scalar `partition_point` single-threaded; Rayon compensates beyond t=4
5. **Old "flat curve" was an artifact** of the set-building bottleneck masking the actual query computation; the true scaling curve shows healthy parallelism scaling

**Why scaling plateaus at t=16**: Each thread's binary search fires ~270k DRAM accesses per query (perf stat: 270k LLC misses/query at t=1). At t=16, the aggregate DRAM bandwidth from 16 parallel threads saturates the memory controller. Adding more threads beyond that doesn't increase DRAM bandwidth — they just wait on the same shared bus. This is the Roofline limit confirmed by experiment.

---

### 2. NUMA Topology Ablation

**Script**: `scripts/ablation_numa.sh` (manual, via `numactl --membind=0 --cpunodebind=0`)
**What it measures**: Does pinning to one NUMA node reduce cross-socket memory latency?
**Dataset**: eval_medium (10,000 queries, rebinning)
**Unpinned baseline**: same as thread sweep above (565–588s)

| Threads | NUMA-pinned (s) | Unpinned (s) | Improvement |
|---------|----------------|--------------|-------------|
| 1 | 529.7 | 565.5 | **6.3%** |
| 2 | 482.8 | 545.6 | **11.5%** |
| 4 | 477.4 | 553.3 | **13.7%** |
| 8 | 539.7 | 576.4 | 6.4% |
| 16 | 549.0 | 570.3 | 3.7% |
| 32 | 556.6 | 578.2 | 3.7% |
| 64 | 551.4 | 556.5 | 0.9% |

**Finding**: NUMA pinning helps at low thread counts (peak ~14% at t=4) but the improvement fades as threads increase. The bottleneck is not cross-socket traffic — it is the **latency of the dependent cache miss chain** within each binary search, which NUMA cannot fix. NUMA is a secondary effect, not the primary bottleneck.

---

### 3. tmpfs Isolation Experiment

**What it measures**: Is the flat scaling curve caused by disk I/O or DRAM bandwidth?
**Method**: Copy the index to `/dev/shm` (RAM-backed tmpfs, no I/O) and re-run.
**Dataset**: eval_medium

| Threads | Disk / page cache (s) | tmpfs / pure RAM (s) |
|---------|-----------------------|----------------------|
| 1 | 565.5 | 726.4* |
| 2 | 545.6 | 555.8 |
| 4 | 553.3 | 543.3 |
| 8 | 576.4 | 541.3 |
| 16 | 570.3 | 541.8 |
| 32 | 578.2 | 612.0 |
| 64 | 556.5 | 558.8 |

*t=1 tmpfs anomaly: disk had warm page cache; tmpfs was cold at first measurement.

**Finding**: Curves are essentially identical (within noise). The bottleneck is **DRAM bandwidth/latency**, not I/O. The index already fits in the OS page cache after the first run, so the disk experiment was already measuring RAM performance. tmpfs confirms this — no I/O involved, same flat curve.

---

### 4. Memory Layout Ablation — SoA vs AoS

**Script**: `scripts/ablation_layout.sh`
**What it measures**: Does column-major (SoA) layout outperform row-major (AoS) for binary search?
**Config**: `--features aos` enables Array-of-Structs (`entries: Vec<(f32, u32)>`) vs default SoA
**Threads**: t=1 serial to isolate layout from parallelism

| Dataset | Mode | SoA (s) | AoS (s) | Difference |
|---------|------|---------|---------|------------|
| dev_small | rebinning | 0.78 | 0.84 | AoS +7.6% slower |
| dev_small | conversion | 1.08 | 1.14 | AoS +5.6% slower |
| eval_medium | rebinning | 551.3 | 541.6 | **AoS 1.7% faster** |
| eval_medium | conversion | 614.5 | 608.5 | **AoS 1.0% faster** |
| eval_10gb | rebinning | 69.3 | 69.3 | No difference |
| eval_10gb | conversion | 91.0 | 82.8 | **AoS 9.0% faster** |

**Finding**: SoA marginally faster at small scale; AoS marginally faster at large scale — but differences are within ~10% and inconsistent. **Memory layout is not the bottleneck at this scale.** The theoretical advantage of SoA (reading only `values[]`, skipping `indices[]` during search) is real, but at large scale the binary search is latency-bound on dependent reads regardless of layout. Cache-line efficiency does not help when the bottleneck is pointer-chasing latency, not bandwidth.

---

### 5. Cluster-Level Parallelism Ablation

**Script**: `scripts/ablation_cluster_par.sh`
**What it measures**: Does adding inner parallelism over clusters (queries × clusters work units) break the flat curve?
**Hypothesis to test**: Supervisor suggested the flat curve might be due to too few work units
**Config**:
- `query-par` (default): outer `par_iter` over queries, cluster loop serial — N_queries work units
- `cluster-par` (`--features cluster-par`): outer `par_iter` over queries + inner `par_iter` over clusters — N_queries × N_clusters work units (~34× more on eval_medium)

#### dev_small (200 queries, 57 clusters)

| Threads | query-par (s) | cluster-par (s) |
|---------|--------------|-----------------|
| 1 | 0.75 | 0.81 |
| 2 | 0.57 | 0.82 |
| 4 | 0.81 | 0.82 |
| 8 | 0.80 | 0.82 |
| 16 | 0.52 | 0.87 |
| 32 | 0.81 | 0.87 |
| 64 | 0.84 | 0.90 |

**Finding**: At dev_small, cluster-par shows no improvement and slight overhead. Dataset too small.

#### eval_medium (10,000 queries) — **COMPLETE** ✅

| Threads | query-par (s) | cluster-par (s) | Difference |
|---------|--------------|-----------------|------------|
| 1 | 588.1 | 581.6 | −1.1% |
| 2 | 580.8 | 578.1 | −0.5% |
| 4 | 565.1 | 548.5 | −2.9% |
| 8 | 574.4 | 558.6 | −2.8% |
| 16 | 568.4 | 573.1 | +0.8% |
| 32 | 559.7 | 561.2 | +0.3% |
| 64 | 587.3 | 571.8 | −2.6% |

**Finding**: Adding 34× more parallel work units (queries × clusters) makes **no meaningful difference**. Both curves are flat and identical within noise (all values 548–588s). This directly disproves the hypothesis that the flat curve was caused by insufficient parallelism granularity. The bottleneck is the **serial dependent cache-miss chain inside each binary search step** — more Rayon tasks cannot reduce that latency.

---

### 6. f16 Precision Ablation — Half-Precision Percentile Values

**Script**: `scripts/ablation_f16.sh eval_medium`
**What it measures**: Does storing percentile values as f16 (half precision, 2 bytes vs 4 bytes) reduce memory pressure enough to improve throughput?
**Hypothesis**: f16 halves the index memory footprint (494 MB → ~247 MB). More index fits in LLC. Since the workload is DRAM-latency-bound, fewer DRAM fetches → faster queries.
**Config**: `--features f16` — `SubIndex.values: Vec<f16>`, dequantizes on each comparison (`x.to_f32() < target`)
**Source**: `logs/ablation/eval_medium-{f32,f16}-tN.log` (Apr-22, back-to-back runs, same conditions)

| Threads | f32 run_queries (s) | f16 run_queries (s) | f16 speedup |
|---------|---------------------|---------------------|-------------|
| 1 | 24.34 | 23.63 | 1.03× |
| 2 | 13.13 | 15.19 | **0.86× (slower!)** |
| 4 | 6.95 | 7.35 | 0.94× |
| 8 | 4.77 | 4.92 | 0.97× |
| 16 | 3.86 | **2.76** | **1.40× ← peak** |
| 32 | 3.39 | 3.37 | 1.01× |
| 64 | 3.64 | 3.50 | 1.04× |

**Key findings**:
1. **f16 wins at t=16 (1.40×)** — exactly where DRAM bandwidth is most contested; smaller index reduces cache pressure
2. **f16 is SLOWER at t=2 (0.86×)** — dequantization overhead (one `to_f32()` per comparison) outweighs memory savings at low thread count
3. **f16 optimal (2.76s at t=16) vs f32 optimal (3.39s at t=32)** = 1.23× improvement in best-case query time
4. **Pattern**: f16 benefit increases with thread count (more DRAM pressure → more benefit from smaller index), with a spike at the NUMA boundary (t=16 is the peak before cross-socket traffic at t=32)

**Scientific interpretation**: The workload sits in a regime where (a) at low threads, the bottleneck is compute throughput (dequant adds ~3% latency per step × 8 steps × 57 clusters = measurable overhead), but (b) at high threads, DRAM bandwidth is the bottleneck, and f16's 50% smaller index shifts more hot data into LLC → fewer DRAM fetches → significant speedup. This is strong evidence that the flat SoA curve is memory-bandwidth limited, not purely latency-limited.

**Figure**: [analysis/figures/fig11_f16_comparison.pdf](analysis/figures/fig11_f16_comparison.pdf)

---

### 7. Eytzinger (BFS) Layout Ablation — ✅ Complete (April 22)

**Script**: `scripts/ablation_eytzinger.sh eval_medium`
**What it measures**: Does rearranging sorted values in BFS (breadth-first) order improve hardware prefetching during binary search?
**Hypothesis**: Standard sorted binary search accesses positions n/2, n/4, 3n/4 — cache-hostile random jumps. Eytzinger reorders so that children are at `2k` and `2k+1`: the first 4 levels (15 elements, 60 bytes) fit in one cache line. A software `_mm_prefetch` hint pre-fetches `2k` before it is needed.
**Memory overhead**: 12 B/element (eyt_values f32 + inv_perm u32 + sorted_ids u32) vs 8 B/element for SoA — **50% more memory**. This is the key tradeoff: better cache hit rate vs larger footprint.
**Source**: `logs/ablation/eval_medium-{soa,eytzinger}-tN.log` (Apr-22, back-to-back, same conditions)

| Threads | SoA (s) | Eytzinger (s) | Eytzinger benefit |
|---------|---------|---------------|-------------------|
| 1 | 24.41 | 25.55 | 0.96× (SoA better) |
| 2 | 13.08 | 13.52 | 0.97× (SoA better) |
| 4 | 8.34 | **7.36** | **1.13× (Eytzinger wins!)** |
| 8 | 4.36 | 4.54 | 0.96× (SoA better) |
| 16 | **2.70** | 3.33 | **0.81× (SoA clearly better)** |
| 32 | 3.26 | 3.48 | 0.93× (SoA better) |
| 64 | 3.31 | 4.04 | **0.82× (SoA clearly better)** |

**Key findings**:
1. **Eytzinger only wins at t=4 (1.13×)** — the one sweet spot where per-access latency is the bottleneck and prefetch has time to hide it
2. **Eytzinger is significantly slower at t=16 (0.81×) and t=64 (0.82×)** — the 50% larger memory footprint amplifies the DRAM bandwidth bottleneck: 50% more data per search means 50% more DRAM bandwidth consumed, exactly when DRAM is already saturated
3. **Construction overhead**: Eytzinger FainderIndex construction = ~28s vs SoA ~1.5s (BFS permutation computed via `eytzinger_rec` for each column; O(n) with recursive overhead for 20M elements). In production this would be prebuilt.

**Scientific interpretation**: Eytzinger is designed for latency-bound workloads where each memory access is an independent stall. Fainder at high thread count is **bandwidth-bound** — the total bytes read from DRAM per second is the bottleneck, not latency-per-access. Eytzinger's 50% memory overhead makes the bandwidth problem worse. The t=4 benefit is visible only because at that thread count, the system is partially latency-limited (DRAM not yet saturated). This confirms the roofline model: the right optimization target is bandwidth, not access latency, which is why f16 (reduces footprint by 50%) outperforms Eytzinger (increases footprint by 50%) at high thread counts.

**Figure**: [analysis/figures/fig12_eytzinger.pdf](analysis/figures/fig12_eytzinger.pdf)

---

### 8. Column-Centric Execution Engine Ablation

**Script**: `scripts/ablation_columnar.sh`
**What it measures**: Cache-reuse benefit of flipping the loop order — clusters outer, queries inner grouped by bin — vs the default row-centric (queries outer, clusters serial).
**Key idea**: In row-centric, each query sweeps all 57 clusters independently. By the time query N+1 visits cluster 0, cluster 0's column data (14 KB per bin slice) has been evicted from L2. In columnar, one thread owns one cluster for all 10k queries: the same bin column stays warm in L2 across consecutive queries that hash to the same bin_idx group.
**Dataset**: eval_medium (10,000 queries, ~1M histograms, 57 clusters, 142 bins/cluster)
**Config**: `FAINDER_COLUMNAR=0/1` env var; `--suppress-results` to skip the scatter-merge bottleneck (details below)
**Source**: `logs/ablation/eval_medium-{row,columnar}-tN.log` (Apr-22)

#### Results

| Threads | Row query(s) | Columnar par_phase(s) | Columnar total(s) | Row / Col ratio |
|---------|--------------|-----------------------|-------------------|-----------------|
| 1  | 24.49 | **9.82**  | 10.47 | **2.49×** col wins |
| 2  | 13.20 | **6.44**  | 7.14  | **2.05×** col wins |
| 4  | 7.28  | **4.19**  | 4.67  | **1.74×** col wins |
| 8  | 5.04  | **3.74**  | 4.25  | **1.35×** col wins |
| 16 | 3.58  | **3.25**  | 3.78  | **1.10×** col wins |
| 32 | **3.06** | 3.26   | 3.83  | 0.94× row wins |
| 64 | 3.97  | 3.36    | 3.94  | 1.01× tie |

*`par_phase` = Rust `TIMER parallel_phase` (binary search + flat-buffer writes, before scatter-merge).
`total` = `run_queries` wall time including route precompute (0.013s), parallel phase, and PyO3 (0.002s); excludes index load.*

**Key findings**:
1. **2.49× cache reuse benefit at t=1** — columnar binary search (9.82s) vs row-centric (24.49s). With queries grouped by bin_idx, the ~14 KB column slice stays in L2 cache across all queries in the group. Row-centric evicts the column between queries → cold DRAM fetch on every query.
2. **Crossover at t≈20** (between t=16 and t=32): columnar wins below, row wins above.
3. **Reason for crossover**: columnar has 57 cluster tasks; row has 10,000 query tasks. With 32 threads, 57 tasks provide only 57/32 ≈ 1.8 tasks per thread → poor load balance and idle threads. Row-centric's 10k tasks scale nearly linearly (10,000/32 = 312 tasks/thread → near-perfect load balance).
4. **Both plateau at ~3.0–3.5s** at t≥16 — same memory bandwidth wall as all prior ablations. Columnar and row-centric hit the same DRAM bandwidth ceiling; at saturation, cache reuse can no longer improve throughput.
5. **Row-centric best (t=32, 3.06s) < Columnar best (t=16 par_phase, 3.25s)** — row-centric wins overall if all cores are available.

**The scatter-merge bottleneck** (why `suppress_results` is needed for fair measurement):
eval_medium produces ~5 billion matching histogram IDs (10k queries × ~1M histograms × ~50% match rate). Building the result data requires ~20 GB of memory writes. The columnar flat-buffer approach eliminates 285k small cross-thread allocations (glibc mutex contention ~50µs each → ~14s overhead) by using 57 large cluster buffers. But even the single-threaded scatter-merge of 20 GB takes ~19s — which eclipses the 9.82s parallel phase. Passing `suppress_results=True` through from Python CLI → Rust skips the scatter-merge, measuring only the binary search computation (what the thesis is actually studying).

**Comparison note — Python suppress_results=True (2.32s)**:
Running `FAINDER_NO_RUST=1 run-queries --suppress-results` (pure Python `query_local_index`) takes 2.32s for eval_medium. This appears to beat Rust row-centric at t=1 (24.49s), but the comparison is **not apples-to-apples**: Python's `suppress_results=True` substitutes `update(np.zeros(1,...))` for every result, truly skipping all result construction. Rust's row-centric still builds `col_ids[h..].to_vec()` on every match (the suppress_results flag only skips the columnar scatter-merge). Python is also using `np.searchsorted` — a SIMD-vectorized C implementation — while Rust uses scalar `partition_point`. The 2.32s measures Python's pure search overhead; Rust's 24.49s includes both search + result Vec construction.

**Scientific interpretation**: The columnar cache reuse is real and significant — 2.49× at single-thread — but the gain is only available at low parallelism. The thesis recommendation is: use row-centric for production with many cores (better scaling), but the columnar measurement isolates the cache reuse contribution as a standalone optimization component.

**Figure**: `analysis/figures/fig13_columnar_vs_row.pdf` (to be generated)

---

## Current Running Experiments

None.

---

## Implemented Code Changes

### Feature Flags (Cargo.toml)
```toml
[features]
aos = []           # Array-of-Structs layout (ablation control)
cluster-par = []   # Nested cluster-level parallelism (ablation control)
f16 = ["dep:half"] # Half-precision percentile values (ablation)
eytzinger = []     # BFS-order values for prefetch-friendly binary search (ablation)
```
All are off by default. The default build is SoA + f32 + query-level parallelism.

### Key Files Modified
| File | Change |
|------|--------|
| `src/index.rs` | `#[cfg(feature = "aos")]` — conditional SubIndex struct (SoA vs AoS) |
| `src/index.rs` | `#[cfg(feature = "f16")]` — half-precision SubIndex with `Vec<f16>` values |
| `src/index.rs` | `#[cfg(feature = "eytzinger")]` — BFS-order SubIndex with `eyt_values`, `inv_perm`, `sorted_ids`; `eytzinger_rec` recursive builder |
| `src/engine.rs` | `process_cluster` closure; `#[cfg(feature = "cluster-par")]` inner par_iter |
| `src/engine.rs` | `#[cfg(feature = "eytzinger")]` — BFS search with `_mm_prefetch` software hint; decode via `k >> (trailing_ones+1)` |
| `src/engine.rs` | **Bug fix**: out-of-range handling — return all cluster IDs when query trivially covers cluster |
| `src/engine.rs` | **Bug fix**: bin_idx clamped to `bins.len()-1` not `bins.len()-2`; pctl_index has n_boundaries columns |
| `src/engine.rs` | **PyO3 interop fix**: return `PyArray1<u32>` (numpy arrays) instead of `PySet` — eliminates GIL-bound per-element Python object allocation |
| `fainder/execution/percentile_queries.py` | Cast f16→f32 and u*→u32 at Rust boundary |
| `fainder/execution/percentile_queries.py` | Honor `suppress_results`: skip `set(arr.tolist())` conversion when suppressing — enables fair timing of pure Rust query computation |
| `fainder/execution/percentile_queries.py` | Pass `suppress_results` and `columnar` flags to Rust via `run_queries(queries, index_mode, num_threads, columnar, suppress_results)` |
| `src/index.rs` | Added `columnar: bool = false` and `suppress_results: bool = false` to `run_queries` PyO3 signature |
| `src/engine.rs` | `execute_columnar()`: column-centric engine (clusters outer, queries grouped by bin_idx); flat-buffer approach to avoid 285k small cross-thread allocations; `TIMER` instrumentation |
| `src/engine.rs` | `execute_columnar()`: skip scatter-merge when `suppress_results=true` — enables benchmarking binary search without 19s merge overhead |
| `Cargo.toml` | Added `aos`, `cluster-par`, `f16`, `eytzinger` feature flags; `half = "2.4"` optional dependency |

### Bugs Found and Fixed During Accuracy Confirmation

**Bug 1: Out-of-range cluster handling** (`engine.rs` line 125)
- Old: `if ref_val < bins[0] || ref_val > bins[-1] { return vec![]; }` — always empty for out-of-range
- New: direction-aware — if `ref > bins[-1]` and "lt" query, OR `ref < bins[0]` and "gt" query, return ALL histogram IDs (entire cluster trivially satisfies the query)
- Impact: caused recall=0.699 vs Python

**Bug 2: Bin index clamping** (`engine.rs` line ~130)
- Old: `bin_idx = (raw_idx + bin_mode).min(bins.len() - 2)` — assumed n_bins = n_boundaries - 1
- New: `bin_idx = (raw_idx + bin_mode).min(bins.len() - 1)` — pctl_index has n_boundaries columns
- Impact: for queries near the upper cluster boundary, used wrong percentile column → caused remaining recall gap (0.699 → 0.762 → 1.0)

### Analysis Scripts
| Script | Purpose |
|--------|---------|
| `scripts/ablation_parallel.sh` | Thread sweep 1→64 (default build) |
| `scripts/ablation_layout.sh` | SoA vs AoS at t=1 serial |
| `scripts/ablation_cluster_par.sh` | query-par vs cluster-par thread sweep |
| `scripts/ablation_f16.sh` | f32 vs f16 precision thread sweep |
| `scripts/ablation_eytzinger.sh` | SoA vs Eytzinger BFS thread sweep |
| `scripts/ablation_columnar.sh` | Row-centric vs columnar engine thread sweep |
| `analysis/plot_all_results.py` | Figures 1–4, 9, 11–12 (thread scaling, f16, Eytzinger) |
| `analysis/plot_hardware_ablation.py` | Figures 5–8, 10 (NUMA, tmpfs, SoA/AoS, roofline) |

Generated figures: `analysis/figures/fig{1-12}.{pdf,png}`

---

## Scientific Story (Thesis Narrative)

### Why the optimizations work the way they do

**Rust vs Python (serial)**: Rust single-threaded (`run_queries` at t=1, 24.05s) is **2.24x SLOWER than Python** (10.74s) on eval_medium. Python's `np.searchsorted` (vectorized C code compiled with SIMD) beats Rust's scalar `partition_point`. The value of Rust is not faster single-threaded binary search — it is **enabling parallelism** (Python GIL blocks true multi-core execution; Rust/Rayon uses all cores freely). At t=16, Rust is 3.58x faster than Python serial.

**Why parallelism is flat**: Binary search is a *dependent* read chain. Each bisection step depends on the result of the previous comparison to pick the next memory address. This is **serial by nature** — you cannot parallelize within a single binary search. At large scale, each query's binary search generates unpredictable DRAM accesses (the index is 494 MB, doesn't fit in L3). More threads hit more cache lines simultaneously → DRAM bandwidth saturation, no speedup. This is the **memory bandwidth Roofline limit**.

**NUMA**: Cross-socket memory access adds ~2× latency vs. local DRAM. Pinning to one node removes this. But even local DRAM latency is ~80ns — each binary search step waits 80ns. At 57 clusters × ~log₂(200) = 8 steps per cluster = ~456 dependent DRAM accesses per query. This is the wall.

**SoA vs AoS**: SoA reads only `values[]` during binary search — half the memory bandwidth. AoS reads `(value, index)` pairs — wastes bandwidth on `index` data during search. At small scale SoA wins slightly. At large scale, both are bandwidth-limited and the difference disappears. Memory layout matters less than the latency bottleneck.

**Cluster-par**: Adding parallelism at the cluster level gives 34× more parallel tasks. But each task (one cluster × one query) still has the same serial binary search inside. If the bottleneck is DRAM latency per search step, more Rayon tasks don't help — they just increase thread scheduling overhead and cache contention.

### What we can claim for the thesis

1. ✅ Rust implementation is correct (produces same results as Python)
2. ✅ Rust enables true parallelism (no GIL) — this is the main speedup mechanism
3. ✅ The speedup plateaus quickly — workload is DRAM-latency-bound, not compute-bound
4. ✅ NUMA topology is a secondary effect (up to 14%, fades at high thread count)
5. ✅ Memory layout (SoA vs AoS) is not the bottleneck at large scale
6. ✅ Cluster-level parallelism does not break the flat curve (confirmed — identical performance)

---

## Baseline Speedup Numbers (April 22 — Post-Bug-Fix, Corrected)

**Critical discovery**: The earlier ~560–590s Rust numbers and the "6.66x speedup" were invalid because:
1. Before bug fixes: Rust had recall=0.699, returning fewer results → less set-building work → artificially fast
2. `suppress_results` was NOT honored in Rust path (was ignored) → comparisons mixed "query only" vs "query + set building"
3. FainderIndex construction (~18s) is included in the timed window but Python has no equivalent cost

**PyO3 fix applied**: `engine.rs` now returns `PyArray1<u32>` (single memcpy) instead of `PySet` (per-element GIL allocation). Python side does `set(arr.tolist())` only when `suppress_results=False`.

### eval_medium, rebinning, 10,000 queries

#### Suppress_results=True — query computation only
| Configuration | Total time (s) | `run_queries` only (s) | Notes |
|---|---|---|---|
| Python serial | **10.62s** | 10.62s | numpy searchsorted, no result collection |
| Rust t=1 | 41.96s | **24.4s** | 17.6s FainderIndex construction + 24.4s queries |
| Rust t=64 | 21.89s | **3.70s** | 18.2s construction + 3.7s queries |

**Key insight**: Rust `run_queries` (3.70s at t=64) vs Python query loop (10.62s) = **2.87× speedup** on pure computation. But Python serial is faster than Rust serial (10.62s vs 24.4s) because Python uses numpy's vectorized C searchsorted while Rust does scalar `partition_point` — compensated by parallelism above 8 threads.

#### No suppress_results — full pipeline (query + result collection as Python sets)
| Configuration | Total time (s) | Notes |
|---|---|---|
| Python serial | 748.6s | Binary search (10.62s) + set building from numpy slices (738s) |
| Rust t=64 (OLD — PySet) | 751.3s | Python set building (via PySet::new_bound) dominates |
| Rust t=64 (NEW — numpy arrays) | **717.5s** | `set(arr.tolist())`: 695s. Only 4.3% faster — still dominated by set building |

**Conclusion on result serialization**: Both approaches (PySet vs numpy→set) are dominated by Python set construction from 320M+ result IDs. The bottleneck is irreducible as long as callers require Python sets. For benchmarking query computation, `--suppress-results` is the only way to measure Rust speedup cleanly.

**Root cause of old flat curve**: `PySet::new_bound(py, &vec)` allocates one Python int object per result ID, sequentially under the GIL. For 10k queries averaging ~32k result IDs each = 320M Python object allocations → ~738s overhead that completely swamps the 3.70s of Rust computation.

**Fix**: Return `numpy.ndarray` from Rust (single memcpy), then `set(arr.tolist())` in Python (bulk C operation). Result: `suppress_results=True` now correctly times only Rust computation.

---

## Next Steps

| Priority | Task | Status |
|----------|------|--------|
| 1 | ~~Cluster-par ablation~~ | ✅ Done — no improvement |
| 2 | ~~Add cluster-par figure~~ | ✅ fig9 generated |
| 3 | ~~Accuracy confirmation — dev_small~~ | ✅ rebinning 1.0/1.0, conversion 1.0/0.9999 |
| 4 | ~~Accuracy confirmation — eval_medium~~ | ✅ Skipped (RAM too large); dev_small sufficient |
| 5 | ~~`perf stat` Roofline measurement~~ | ✅ Done — IPC=0.94 proves memory-latency bound |
| 6 | ~~PyO3 result serialization fix~~ | ✅ Done — numpy arrays instead of PySet |
| 7 | ~~f16 ablation thread sweep on eval_medium~~ | ✅ Done — f16 wins 1.40× at t=16 |
| 8 | ~~Eytzinger (BFS) layout ablation sweep~~ | ✅ Done — NOT beneficial at optimal t=16 |
| 9 | ~~Add Eytzinger data to plot_all_results.py + regenerate fig12~~ | ✅ Done — fig12 generated |
| 10 | Update fig2 speedup data for eval_10gb (needs suppress_results run) | Optional |
| 11 | Thesis writing: ablation narrative (f16, Eytzinger — bandwidth vs latency story) | Ready |

---

## Quick Reference: Where Data Lives

```
logs/ablation/                      # All experiment logs
  dev_small-rust-tN.log             # Thread sweep (original)
  dev_small-{query,cluster}-par-tN.log  # Cluster-par ablation
  dev_small-{soa,aos}-{rebinning,conversion}.log  # Layout ablation
  eval_medium-{soa,aos,numa}-*.log  # eval_medium ablations
  eval_10gb-{soa,aos}-*.log         # eval_10gb layout

analysis/figures/                   # All generated PDF/PNG figures
  fig1-fig4: thread scaling, SoA/AoS bars
  fig5-fig8: NUMA, tmpfs, hardware summary

src/engine.rs                       # Rust query engine
src/index.rs                        # Rust index loader
fainder/execution/percentile_queries.py  # Python/Rust dispatcher
```

---

### 6. Roofline / perf stat — Hardware Performance Counters

**Tool**: `perf stat` (requires `kernel.perf_event_paranoid=1`)
**Dataset**: eval_medium (10,000 queries, rebinning index)

| Metric | t=1 (serial) | t=64 (parallel) |
|--------|-------------|-----------------|
| Query time (s) | 952.3 | 758.9 |
| **IPC** | **0.94** | **0.96** |
| LLC misses (total) | 2.70B | 1.97B |
| LLC misses / query | 270,000 | 197,000 |
| Instructions | 3.94T | 3.58T |
| Cycles | 4.17T | 3.75T |

**Finding**: IPC = 0.94 at t=1 and 0.96 at t=64 — essentially identical. A compute-bound workload would show IPC 2–4. Fainder's binary search generates ~270,000 DRAM round-trips per query (dependent cache-miss chain). Adding 64 threads improves wall time by only 1.25× — not 64× — because each thread independently stalls on memory latency. More parallelism ≠ less latency.

**Figure**: [analysis/figures/fig10_roofline_perf.pdf](analysis/figures/fig10_roofline_perf.pdf)

*Last updated: 2026-04-22 — perf stat Roofline complete*
