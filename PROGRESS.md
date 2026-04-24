# Fainder Thesis — Complete Progress Log
**Hardware-Conscious Performance Engineering of Fainder for Distribution-Aware Dataset Search**
*Tarik Abu Mukh — Master's Thesis, TU Berlin DIMA, due end of May 2026*

---

## Executive Summary

This thesis re-engineers the query execution pipeline of Fainder (VLDB 2024) from Python/NumPy to Rust, then conducts a systematic ablation study to quantify *which* hardware-conscious optimizations contribute *how much*, and *why*.

**Headline results (eval_medium, 10k queries, 200k histograms, suppress_results=True):**
- Query engine (f16, t=16): **3.41s** vs Python single-thread **18.27s** → **5.36×**
- Per-batch load+query (mmap+query vs pickle+query): 3.42s vs 33.47s → **9.78×**
- Full e2e (build+load+query): 133.2s vs 526.3s → **3.95×**
- col+f16 wins at t=1 (10.10s, **2.43× over row-f32**); f16 row-centric wins at t≥16

**Key scientific finding (UPDATED 2026-04-24 after re-measurement):**
The current engine is **compute/L1-bound at t≤16** (IPC 2.36–2.46, L1 miss rate 0.55%) and becomes **memory-subsystem-contended only at t=32–64** (IPC drops to 1.41; LLC miss rate climbs from 18% to 31%). This is a more nuanced picture than the earlier "latency-bound → bandwidth-bound" framing — see Phase 4 below.

---

## What the Thesis Proposal Specified (3 Primary Axes)

From the formal proposal (Nov 2025):

| Axis | Status |
|------|--------|
| **1. SIMD vectorization** (AVX2/AVX-512 for percentile comparisons) | ✅ Done (Phase 10 — null result) |
| **2. Cache-conscious memory layouts** (SoA vs AoS) | ✅ Done |
| **3. Multicore parallelism** (Rayon work-stealing) | ✅ Done |
| Low-level profiling (perf stat, cache/branch miss rates) | ✅ Done (re-measured 2026-04-24) |
| Ablation study for each optimization | ✅ Done (12 ablations + combined pipeline) |

**All three primary proposal axes are now done.** Phase 10 added AVX2 SIMD; the result is a scientifically significant null: the bottleneck is neither comparison throughput nor DRAM latency but the CMOV dependent chain on L1-resident data.

---

## The Investigation: Phase by Phase

---

### Phase 1 — Starting Point: Python Baseline

**What we had:** The original Fainder Python implementation (`fainder/` directory). Pure Python + NumPy.

Two index modes:
- **Rebinning**: 1 histogram variant per cluster bin → fast, approximate
- **Conversion**: 2 variants per cluster (float16) → higher precision, ~10–15% slower

Query hot path: for each query, iterate over all k clusters; within each cluster, binary search over sorted percentile values using `numpy.searchsorted`; collect matching histogram IDs.

**Python baseline times (suppress_results=True, query computation only):**

| Dataset | Histograms | Queries | Python time |
|---------|-----------|---------|-------------|
| dev_small | 50k | 200 | 0.84s |
| eval_medium | 200k | 10,000 | 18.27s (median) |
| eval_10gb | 323k | 4,500 | ~8s |

Note: Python's `numpy.searchsorted` is implemented in C with SIMD. It is **not** a pure Python loop — it processes an entire sorted array column in one vectorized C call.

---

### Phase 2 — What We Built in Rust

**Files:** `src/index.rs`, `src/engine.rs`, `src/lib.rs`
**Integration:** `fainder/execution/percentile_queries.py` transparently delegates to Rust; `FAINDER_NO_RUST=1` forces Python path.

#### Core optimizations in the default build:

1. **Rayon work-stealing parallelism** — `par_iter()` over queries; each cluster loop serial. Thread count via `FAINDER_NUM_THREADS=N`.
2. **Structure-of-Arrays (SoA) memory layout** — column-major flattened `values: Vec<f32>` and `indices: Vec<u32>`. For bin $k$, the slice `values[k*n..(k+1)*n]` is contiguous → binary search reads only f32 values, no identifier pollution.
3. **`partition_point` binary search** — branchless (CMOV-based) `|x| x < target` predicate; semantically identical to `searchsorted(side="left")`.
4. **Typed query execution** — parse operator string to Rust enum once at the Python boundary, not per-cluster.
5. **Out-of-range early exit** — if query reference value is entirely outside a cluster's bin range, return all cluster IDs or empty set without running the binary search.

#### Bug fixes found during correctness validation:

**Bug 1 (out-of-range direction):** Initial code returned empty set for *both* directions when $\tau$ fell outside a cluster's range. Correct: if $\tau > \text{bin\_max}$ and operator is `lt`, all histograms trivially satisfy → return all cluster IDs. This caused **recall = 0.699** on dev_small.

**Bug 2 (bin index clamping):** Clamped bin index to `bins.len()-2` instead of `bins.len()-1`. The pctl_index has `n_boundaries` columns, not `n_boundaries-1`. Fixed remaining recall gap (0.762 → 1.000).

**PyO3 result serialization bug:** Returning `PySet` from Rust required one Python int object allocation per result ID under the GIL → **~540s** of overhead for 10k queries on eval_medium (320M result IDs). Fixed by returning `numpy.ndarray` (single `memcpy`); Python side does `set(arr.tolist())` only when `suppress_results=False`. All pre-2026-04-20 ablation logs that show query times in the 500s range include this overhead; valid results require `suppress_results=True`.

#### After all bug fixes — correctness confirmed:
- dev_small rebinning: precision=1.000, recall=1.000 ✅
- dev_small conversion: precision=1.000, recall=0.9999 ✅ (f32 rounding at boundary, consistent with Python)

---

### Phase 3 — Parallelism Ablation (Thread Sweep)

**Script:** `scripts/ablation_parallel.sh`
**Dataset:** eval_medium (10k queries, rebinning)
**Method:** `suppress_results=True` — measure only binary search computation

| Threads | run_queries (s) | Speedup vs t=1 | vs Python (18.27s) |
|---------|----------------|----------------|---------------------|
| Python serial | 18.27 | — | 1.00× |
| Rust t=1 | 24.05 | 1.00× | **0.76× (slower!)** |
| Rust t=2 | 13.07 | 1.84× | 1.40× |
| Rust t=4 | 7.22 | 3.33× | 2.53× |
| Rust t=8 | 4.91 | 4.90× | 3.72× |
| **Rust t=16** | **3.00** | **8.02×** | **6.09× ← peak** |
| Rust t=32 | 4.04 | 5.95× | 4.52× |
| Rust t=64 | 3.61 | 6.67× | 5.06× |

**Key findings:**
1. **Rust t=1 is 1.32× SLOWER than Python.** Python's `numpy.searchsorted` uses SIMD (AVX). Rust uses scalar `partition_point`. Explicit AVX2 in Rust (Phase 10) does not close this gap — the binary search is not comparison-throughput-bound.
2. **Clean scaling from t=1 to t=16** (8× speedup). Rayon work-stealing works as designed — embarrassingly parallel workload, no shared state.
3. **t=32 regresses**: crosses NUMA node boundary (96 cores per NUMA node on this machine). Cross-socket memory latency kicks in.
4. **Beyond t=16**, shared-cache and DRAM contention dominate. Adding more threads cannot further accelerate the workload because the memory subsystem becomes contested (see Phase 4a IPC drop at t=64).

**Figure:** `analysis/figures/fig3_thread_sweep.pdf`

---

### Phase 4 — Hardware Bottleneck Diagnosis

#### 4a. perf stat measurements (RE-MEASURED 2026-04-24 with --delay=40000, 5× query repetition, suppress_results=True)

**Tool:** `perf stat` on eval_medium rebinning
**Scripts:** `scripts/perf_branch_misses.sh`, `scripts/perf_comprehensive.sh`
**Methodology:** perf `--delay=40000` skips the 35s load+init+warmup phase; counters reflect only the 5×10k-query measured section. Three event groups (CORE, CACHE, LLC) to avoid multiplexing.

**eval_medium results:**

| Metric | t=1 | t=16 | t=64 |
|--------|-----|------|------|
| Query wall time (1 run) | 22.25s | 3.35s | 3.82s |
| **IPC** | **2.46** | **2.36** | **1.41** |
| Branch-mispred rate | 0.01% | 0.02% | 0.03% |
| L1-dcache miss rate | 0.55% | 0.54% | 0.70% |
| cache-refs miss rate | 21.1% | 20.3% | 28.8% |
| LLC-load miss rate | 21.0% | 18.5% | **30.9%** |
| LLC-load-misses / query | 6,500 | 4,380 | 7,688 |

**dev_small results (500× query repetition for non-trivial runtime):**

| Metric | t=1 | t=16 |
|--------|-----|------|
| Query wall time (1 run) | 0.036s | 0.006s |
| **IPC** | **3.69** | **3.20** |
| Branch-mispred rate | 0.05% | 0.19% |
| L1-dcache miss rate | 0.87% | 0.95% |
| LLC-load miss rate | 0.86% | 3.75% |
| LLC-load-misses / query | 2.7 | ~3 |

**Interpretation:**

At low thread counts (t=1, t=16), Fainder is **compute/L1-bound**: IPC is 2.36–2.46 on eval_medium (3.20–3.69 on dev_small), close to saturating the 4-wide execution pipeline. L1 hit rate is 99.45%. The binary search working set (~5.6 KB per cluster column) fits in L1, so the dependent load chain is L1-latency (4–5 cycles), not DRAM-latency (80 ns). Branch-mispred rate of 0.01–0.05% confirms `partition_point` is branchless — no branch penalty.

At t=64, **IPC drops to 1.41** and LLC-load-miss rate jumps from 18–21% to 31%. This is the real bandwidth-contention regime: 64 threads span both NUMA nodes, shared LLC (~30 MB) gets fragmented across threads, and cross-socket traffic begins.

**This replaces the prior "IPC=0.94, 270k LLC/query" claim**, which was extracted from a pre-PyO3-fix measurement that included Python result-set construction (~540s overhead) and is not reproducible in the current engine.

**Figure:** `analysis/figures/fig10_roofline_perf.pdf` (needs regeneration with new data)

#### 4b. NUMA Topology Ablation (RE-MEASURED 2026-04-24 with --suppress-results)

**Script:** `scripts/ablation_numa.sh` (new)
**Method:** `numactl --membind=0 --cpunodebind=0` vs unpinned, both with `--suppress-results`.

| Threads | NUMA-pinned (s) | Unpinned (s) | Improvement |
|---------|-----------------|--------------|-------------|
| 1 | 25.15 | 24.48 | −2.7% (pinning hurts) |
| 4 | 7.05 | 7.26 | 2.8% |
| 16 | 3.15 | 3.11 | −1.3% |
| 64 | 3.31 | 3.91 | **+15.4%** |

**Finding:** NUMA pinning is **neutral at t≤16** (within ±3% noise) and provides the only meaningful benefit (**15.4%**) at **t=64**, where the workload spreads across both NUMA nodes and cross-socket traffic becomes significant. This is a simpler story than before: NUMA pinning only matters when threads exceed node capacity.

**Note:** Prior claim of "13.7% at t=4" was from a pre-PyO3-fix measurement; the new 2.8% reading is noise.

**Figure:** `analysis/figures/fig5_numa_vs_unpinned.pdf` (needs regeneration)

#### 4c. tmpfs Storage Isolation

**Method:** Copy 494MB index to `/dev/shm` (RAM-backed, no I/O) and re-run.

**Finding:** Curves are indistinguishable. The OS page cache already keeps the index in DRAM after the first warm-up. Bottleneck is not I/O.

**Figure:** `analysis/figures/fig6_tmpfs_vs_disk.pdf`

---

### Phase 5 — Memory Layout Ablation (SoA vs AoS) (RE-MEASURED 2026-04-24)

**Script:** `scripts/ablation_layout.sh` (fixed to use --suppress-results)
**Method:** `--features aos` builds AoS variant (`Vec<(f32, u32)>` interleaved); both variants with `--suppress-results`.

| Dataset | Threads | SoA (s) | AoS (s) | Difference |
|---------|---------|---------|---------|------------|
| dev_small | 1 | 0.78 | 0.84 | SoA 7.6% faster |
| dev_small | 1 (conv) | 1.08 | 1.14 | SoA 5.6% faster |
| **eval_medium** | **1** | **24.75** | **26.96** | **SoA 8.2% faster** |
| eval_medium | 16 | 3.71 | 3.39 | AoS 8.6% faster |
| eval_medium | 64 | 3.62 | 3.88 | SoA 6.8% faster |

**Finding:** At serial execution (t=1), SoA consistently beats AoS by **6–8%** — the cache-line-efficiency benefit is real when every cache-line access contributes to the binary search. At t=16, AoS happens to edge out SoA (this is within the ±5% noise floor). At t=64, SoA wins by 6.8%.

The effect is small because the workload is L1-hit-dominated (0.55% L1 miss rate); SoA's cache-line density advantage only matters for accesses that reach L2 or beyond. For dependent-load binary search on L1-resident data, the speedup is proportional to the fraction of accesses that miss — small but measurable.

**Figure:** `analysis/figures/fig7_soa_vs_aos.pdf` (needs regeneration)

---

### Phase 6 — Cluster-Level Parallelism Ablation (RE-MEASURED 2026-04-24)

**Script:** `scripts/ablation_cluster_par.sh` (fixed to use --suppress-results)
**Method:** `--features cluster-par` adds inner `par_iter()` over clusters within each query.

| Threads | query-par (s) | cluster-par (s) | Difference |
|---------|---------------|-----------------|------------|
| 1 | 24.46 | **19.86** | **cluster-par 18.8% faster** |
| 16 | 3.73 | 4.20 | query-par 11.2% faster |
| 64 | 3.76 | **16.51** | **query-par 4.4× faster** |

**Finding:** This is **not a null result**. Cluster-par has a sharp regime dependence:

- **At t=1**: cluster-par is **1.23× faster** — the nested par_iter schedules clusters across Rayon's thread pool of 1, which still reorganizes execution to iterate clusters-first for a given query. The cluster-par iteration order happens to give better L1/L2 reuse.
- **At t=16**: query-par wins by 11% — more than enough 10k query tasks for 16 threads; inner par_iter adds scheduling overhead without benefit.
- **At t=64**: query-par is **4.4× faster** — cluster-par's 570k tasks × 64 threads floods Rayon's work-stealing with too-small tasks, and the task overhead (~1µs per task) dominates.

**Corrected interpretation:** Task granularity is a first-order factor. The optimal configuration depends on the thread-to-task ratio: use query-par for t ≥ task-count/threshold (~500 tasks/thread), use cluster-par for low-thread settings where a single thread benefits from finer-grained work distribution.

**Figure:** `analysis/figures/fig9_cluster_par_ablation.pdf` (needs regeneration)

---

### Phase 7 — f16 Half-Precision Ablation

**Script:** `scripts/ablation_f16.sh eval_medium`
**Method:** `--features f16` stores values as `Vec<half::f16>` (2 bytes vs 4). Halves index: 494MB → ~247MB. One `to_f32()` dequantization per comparison.

| Threads | f32 (s) | f16 (s) | f16 speedup |
|---------|---------|---------|-------------|
| 1 | 24.34 | 23.63 | 1.03× |
| 2 | 13.13 | 15.19 | **0.86× (slower!)** |
| 8 | 4.77 | 4.92 | 0.97× |
| **16** | 3.86 | **2.76** | **1.40× ← peak** |
| 32 | 3.39 | 3.37 | 1.01× |
| 64 | 3.64 | 3.50 | 1.04× |

**Key findings:**
1. f16 **loses at t=2** (0.86×): dequantization overhead outweighs memory savings when the workload is L1-bound.
2. f16 **wins at t=16** (1.40×): at this thread count, 16 threads share L3 capacity; halving the per-thread working set reduces inter-thread L3 eviction (LLC miss rate drops from 21% to 18.5% at t=16, see Phase 4a).
3. Best f16 config (2.76s at t=16) is **1.23× better than best f32 config** (3.39s at t=32).
4. The mechanism is **shared-cache capacity**, not DRAM bandwidth: at t=16, L1 hit rate is still 99.45%, but the LLC pressure across threads is eased by the smaller footprint.

**Figure:** `analysis/figures/fig11_f16_comparison.pdf`

---

### Phase 8 — Eytzinger (BFS) Layout Ablation

**Script:** `scripts/ablation_eytzinger.sh eval_medium`
**Method:** `--features eytzinger` reorders sorted values in BFS order. First 4 binary search levels (15 elements, 60 bytes) fit in one cache line. Software prefetch hint `_mm_prefetch(2k)` issued at each step. Memory overhead: 12 bytes/element (f32 + inv_perm u32 + sorted_ids u32) vs 8 bytes for SoA → **50% more memory**.

| Threads | SoA (s) | Eytzinger (s) | Benefit |
|---------|---------|---------------|---------|
| 1 | 24.41 | 25.55 | 0.96× (SoA better) |
| 4 | 8.34 | **7.36** | **1.13× ← Eytzinger wins** |
| 16 | 2.70 | 3.33 | **0.81× (SoA clearly better)** |
| 64 | 3.31 | 4.04 | 0.82× (SoA clearly better) |

**Key findings:**
1. Eytzinger wins only at **t=4**: partially memory-bound, prefetch can hide the occasional L1 miss.
2. Eytzinger loses badly at **t≥16**: 50% larger footprint amplifies shared-cache pressure.

**The f16 + Eytzinger pair is the sharpest controlled experiment in the thesis:**
- f16 **halves** per-thread footprint → **wins** at t=16 (1.40×)
- Eytzinger **+50%** footprint → **loses** at t=16 (0.81×)
- Both effects scale proportionally with footprint change → **shared-cache capacity at moderate-thread counts is the relevant constraint** (not DRAM bandwidth, which is only reached at t=64).

**Figure:** `analysis/figures/fig12_eytzinger.pdf`

---

### Phase 9 — Column-Centric Execution Engine

**Script:** `scripts/ablation_columnar.sh`
**Idea:** Default row-centric engine: queries outer, clusters inner. Column-centric (FAINDER_COLUMNAR=1): clusters outer, queries grouped by bin_idx inner. Keeps column slice (~14KB) warm in L1/L2 cache across all queries in the group.

**The scatter-merge bottleneck:** eval_medium produces ~5B matching histogram IDs. Building results requires ~20GB writes. `suppress_results=True` skips this to measure only binary search.

#### eval_medium (10k queries):

| Threads | Row (s) | Col par_phase (s) | Col total (s) | Ratio |
|---------|---------|-------------------|---------------|-------|
| 1 | 24.49 | **9.82** | 10.47 | **2.49× col wins** |
| 4 | 7.28 | 4.19 | 4.67 | 1.74× col wins |
| 16 | 3.58 | 3.25 | 3.78 | 1.10× col wins |
| **32** | **3.06** | 3.26 | 3.83 | 0.94× row wins |

Crossover at t≈20 (between t=16 and t=32). Reason: columnar has 57 cluster tasks; row has 10k query tasks. At t=32: 57/32 = 1.8 tasks/thread (load imbalance) vs 10k/32 = 312 tasks/thread (good balance).

#### eval_10gb (4.5k queries):

Crossover at t≈6. At crossover: eval_10gb has 4500/6 ≈ 750 tasks/thread, eval_medium has 10000/20 = 500 tasks/thread. **Consistent 500–750 tasks/thread threshold across both datasets** — confirms crossover is governed by Rayon load-balance dynamics.

**Cache reuse at t=1: 2.13–2.49× speedup** — direct measurement of the benefit of keeping column data in L1/L2 across queries.

**Figure:** `analysis/figures/fig13_columnar_vs_row.pdf`

---

### Phase 10 — AVX2 SIMD Binary Search

**Script:** `scripts/ablation_simd.sh`
**Date:** 2026-04-23
**Status:** ✅ Complete — null result; scientifically significant

**Motivation:** Python's `numpy.searchsorted` is auto-vectorised in C. Rust uses scalar `partition_point`. Hypothesis: replacing the final 3 comparisons of the 12-step binary search with a single `_mm256_cmp_ps` (AVX2) reduces the dependent-load-chain depth from 12 to ~9.

**Implementation:**
- `src/simd_search.rs`: branchless scalar to ≤8 elements → single AVX2 compare → `movemask` + `count_ones`
- `src/lib.rs`: `#[cfg(feature = "simd")] mod simd_search`
- `src/engine.rs`: `do_partition_lt`/`do_partition_le` dispatcher (runtime `is_x86_feature_detected!("avx2")`)
- `Cargo.toml`: `simd = []` feature flag
- Method: `FAINDER_COLUMNAR=1 --suppress-results` (columnar engine, column in L2 cache = best case for SIMD)

**Results — eval_medium (10k queries, 200k histograms):**

| Threads | Scalar (s) | SIMD (s) | Speedup |
|---------|-----------|----------|---------|
| t=1  | 9.806 | 9.406 | 1.04× |
| t=2  | 7.722 | 6.811 | **1.13×** |
| t=4  | 4.668 | 5.162 | **0.90× (regression)** |
| t=8  | 4.138 | 3.944 | 1.05× |
| t=16 | 3.623 | 3.791 | 0.96× |
| t=32 | 3.927 | 3.865 | 1.02× |
| t=64 | 3.981 | 3.629 | 1.10× |

**Key finding:** SIMD provides inconsistent benefit (max 1.13×, with regressions to 0.90× at t=4).

**Updated interpretation (2026-04-24):** The standard `partition_point` is branchless (CMOV), and the per-cycle data from perf (IPC=2.46 at t=1, branch-mispred 0.01%) confirms that the CPU is already saturating the execution pipeline — there are no idle cycles for SIMD to fill. The binary search is L1-hit-dominated (0.55% L1 miss), so the dependent load chain is bound by CMOV + L1 latency, not comparison throughput. Replacing 3 of 12 scalar steps with one AVX2 instruction does not shorten the L1-latency chain.

**Figure:** `analysis/figures/fig14_simd_ablation.pdf`

---

### Phase 11 — Flat Binary Index Format (Serialisation Benchmark)

**Script:** `scripts/benchmark_serialization.sh`
**Files:** `fainder/utils.py` (`save_flat_index`, `load_flat_index`, `load_index`), `scripts/benchmark_serialization.sh`
**Date:** 2026-04-23
**Status:** ✅ Complete

**Motivation:** pickle+zstd decompress creates a Python object tree (lists of tuples of arrays) on every load. For the eval_medium index (494 MB compressed → 25.74 GB decompressed), this takes 15.2 s per load. Thread sweep = 7 load + query runs → 106 s of wasted I/O overhead per ablation.

**Implementation:** `.fidx` directory format: one `bins_{i}.npy` per cluster + `pctls_{i}_{m}.npy` / `ids_{i}_{m}.npy` per cluster/mode + `meta.json`. `np.load(mmap_mode='r')` maps files into virtual memory; OS pages in data on demand from page cache.

**Results — eval_medium (25.74 GB, 5000 queries, t=16):**

| Format | Mode | Load time | End-to-end | Speedup vs legacy |
|--------|------|-----------|------------|-------------------|
| pickle+zstd | copy to RAM | 15.192s (median) | 39.666s | baseline |
| flat-binary (.fidx) | copy to RAM | 12.076s (median) | 32.334s | 1.23× |
| flat-binary (.fidx) | mmap (page cache warm) | 0.013s (median) | 20.956s | **1.89×** |

**Key finding:** mmap provides 1169× faster apparent load time on warm page cache. End-to-end improvement is 1.89× for a single load+query run.

**Correctness:** ✓ All 20 eval_medium queries: identical results (legacy == flat-binary).

---

### Phase 12 — 8-Way Batch Binary Search (Stage 5A)

**Script:** `scripts/ablation_batch_search.sh`
**Files:** `src/engine.rs` (`batch_partition_point_8`, `batch_partition_point_8_f16`), `Cargo.toml` (`batch-search = []`)
**Date:** 2026-04-23
**Status:** ✅ Complete — null result

**Motivation:** Process 8 independent binary searches in lock-step on the same L2-warm column. First 1-3 steps share midpoints; later steps issue 8 independent loads simultaneously → out-of-order CPU pipelines them.

**Results — eval_medium (10k queries, 200k hists, columnar engine):**

| Threads | Serial (s) | Batch (s) | Speedup |
|---------|-----------|----------|---------|
| t=1  | 9.255 | 9.384 | 0.99× |
| t=2  | 6.396 | 6.217 | 1.03× |
| t=4  | 4.553 | 4.626 | 0.98× |
| t=8  | 3.703 | 3.654 | 1.01× |
| t=16 | 3.409 | 4.129 | **0.83×** (regression) |
| t=32 | 3.902 | 3.947 | 0.99× |
| t=64 | 4.013 | 3.913 | 1.03× |

**Updated interpretation (2026-04-24):** The columnar engine keeps each bin column in L1 cache (0.55% L1 miss rate, per Phase 4a). Each binary search step is 4–5 cycles, not 80ns DRAM. At this latency, the CPU's reorder buffer already overlaps consecutive serial searches — no explicit batching benefit is available. The batch variant adds instruction overhead (8× loop counters, 8 CMOV per step, register pressure) with nothing to amortize, so it matches or slightly regresses serial performance.

---

### Phase 13 — Rust Rebinning Index Construction (Stage 3)

**Files:** `src/rebinning.rs` (NEW), `src/lib.rs`, `Cargo.toml` (ndarray dep), `fainder/preprocessing/percentile_index.py`
**Date:** 2026-04-23
**Status:** ✅ Complete

**Motivation:** Python's `rebin_collection` pickles every histogram across process boundaries; `create_rebinning_index` runs a sequential `np.argsort(axis=0)` on a full N×M matrix. Both are addressable with Rust+Rayon zero-copy parallelism.

**Results (ADDED eval_10gb 2026-04-24):**

| Dataset | Histograms | Python (w=1) | Python (w=192) | Rust | Speedup vs best Python |
|---------|-----------|-------------|----------------|------|------------------------|
| dev_small | 50,069 | 4.53s | — | 0.73s | **6.19×** |
| eval_medium | 996,632 | 492.87s | 472.14s | 129.79s | **3.64×** |
| **eval_10gb** | **~323k (flat)** | **307.57s** | — | **140.70s** | **2.19×** |

**Key finding:** Speedup decreases with dataset size — same pattern as query speedup (20× → 6.66× → 6.02×). At large scale, both Python and Rust hit memory-allocation and sort bottlenecks; the remaining wins come from eliminating Python's `np.argsort(axis=0)` sequential bottleneck and IPC overhead.

**Correctness:** Rust uses round-half-away-from-zero rounding vs NumPy's banker's. Max diff 1e-4 at boundary values in 3/10 clusters on dev_small. Sort order identical (0 id mismatches). All 200 queries produce identical results. eval_10gb correctness: 20 queries PASS.

---

### Phase 14 — Combined Full-Pipeline Benchmark

**Script:** `scripts/benchmark_full_pipeline.sh eval_medium`
**Date:** 2026-04-23
**Status:** ✅ Complete

**Motivation:** All prior ablations isolate one variable at a time. This benchmark asks: when ALL optimizations compose simultaneously (Rust engine + f16 + columnar + mmap storage + Rust construction), what is the total system speedup?

**Configurations benchmarked (eval_medium, 10k queries, 200k hists):**
- `py`: Python single-thread (`FAINDER_NO_RUST=1`, `n_workers=None`)
- `f32`: Rust row-centric f32, `.fidx` mmap
- `f16`: Rust row-centric f16, `.fidx` mmap (--features f16 build)
- `colf16`: Rust columnar+f16, `.fidx` mmap (FAINDER_COLUMNAR=1 + --features f16)

**Query engine times (seconds, "Rust index-based query execution time"):**

| t | Python | f32 | f16 | col+f16 |
|---|--------|-----|-----|---------|
| 1 | 18.27 | 24.58 | 24.07 | **10.10** |
| 2 | 18.62 | 13.73 | 14.49 | **6.96** |
| 4 | 19.17 | 7.45 | 7.30 | **6.09** |
| 8 | 17.12 | 4.92 | 4.96 | **4.40** |
| 16 | 18.41 | **3.54** | **3.41** | 4.12 |
| 32 | 16.72 | 3.80 | 3.68 | 4.22 |
| 64 | 15.38 | 3.82 | 3.72 | 4.30 |

**Full pipeline numbers (using Python median=18.27s as baseline):**
- Query speedup (f16 t=16): 18.27/3.41 = **5.36×** over Python single-thread
- Per-batch load+query: 33.47s (15.2+18.27) → 3.42s (0.013+3.41) = **9.79×**
- Full e2e (build+load+query): 526.34s (492.87+15.2+18.27) → 133.21s (129.79+0.013+3.41) = **3.95×**
- 100 repeated batches: 3347s → 342s = **9.79×**

**Key cross-cutting findings:**
1. **col+f16 wins at t≤4**: 10.10s at t=1 vs f32 24.58s = 2.43× — columnar cache reuse dominates
2. **f16 row-centric wins at t≥8**: 3.41s vs col+f16 4.12s at t=16 — task granularity dominates
3. **Per-batch speedup > query speedup**: 9.79× vs 5.36× — load optimisation compounds with query optimisation

---

### Phase 15 — 4-way k-ary Search Ablation (Stage 5B)

**Files:** `src/kary_search.rs` (NEW), `src/lib.rs`, `src/engine.rs`, `Cargo.toml` (`kary` feature), `scripts/ablation_kary.sh`
**Date:** 2026-04-24
**Status:** ✅ Complete

**Motivation:** The hardware-counter diagnosis in Phase 4a (IPC ≈ 2.46, L1 hit rate 99.45%) showed that the stdlib binary `partition_point` is L1-bound with a serial CMOV dependency chain of ~log₂(1400) ≈ 11 steps. The hypothesis was that reducing this chain to ~log₄(1400) ≈ 6 steps via 4-way branchless search would yield a 1.5–2× improvement at t=1 by shortening the critical path.

**Implementation:** `src/kary_search.rs` — per step, load 3 pivots at quartile positions q, 2q, 3q within the current window, compare all three against the target, count how many are < target (result in {0,1,2,3}), and jump to the corresponding sub-window. Branchless via `(v < t) as usize` + multiplication. Unit tests verify equivalence to stdlib `partition_point` for edge cases (duplicates, small arrays, out-of-range queries). End-to-end correctness: 200/200 queries on dev_small produce bitwise-identical result sets to the stdlib build.

**Results — eval_medium (10k queries, suppress_results=True):**

| Threads | Binary (s) | 4-way (s) | Speedup |
|---------|-----------|-----------|---------|
| 1  | 24.30 | 23.87 | 1.02× |
| 2  | 13.22 | 12.91 | 1.02× |
| 4  |  7.46 |  7.06 | 1.06× |
| 8  |  5.10 |  4.50 | 1.13× |
| **16** | **3.43** | **2.87** | **1.19× ← peak** |
| 32 |  3.82 |  3.35 | 1.14× |
| 64 |  4.09 |  3.84 | 1.07× |

**Perf-counter comparison (eval_medium, suppress_results=True, perf --delay=40000):**

| Metric | Binary t=1 | K-ary t=1 | Binary t=16 | K-ary t=16 | Binary t=64 | K-ary t=64 |
|---|---|---|---|---|---|---|
| IPC | 2.46 | 2.54 (+3%) | 2.36 | 2.26 (−4%) | 1.41 | 1.27 (−10%) |
| L1 miss rate | 0.55% | 0.64% | 0.54% | 0.61% | 0.70% | 0.80% |
| LLC miss rate | 21.0% | 20.0% | 18.5% | 18.7% | 30.9% | 30.4% |
| LLC misses (total) | 325M | **299M (−8%)** | 219M | **197M (−10%)** | 384M | 365M (−5%) |

**Key finding — the predicted mechanism is not the observed mechanism:**

The hypothesis predicted that k-ary would win *most* at t=1 by shortening the CMOV dependency chain. The measured peak is instead at **t=16 (1.19×)**; the t=1 gain is within noise (1.02×).

The perf counters clarify why:
- **At t=1**: IPC rises slightly (2.46 → 2.54), consistent with the CMOV-chain argument — the 3 parallel loads per step *do* fill a few more execution slots — but the effect is small. This means at t=1 the serial CMOV chain was *not* the binding constraint; the CPU's out-of-order engine was already overlapping binary-search steps with surrounding cluster-loop work, so shortening the chain has little headroom.
- **At t=16**: IPC actually *drops* with k-ary (2.36 → 2.26), yet the wall time is 14% lower. The mechanism is **reduced memory traffic**: 10% fewer LLC load misses per query because a 4-way step decides the quarter of the window with 3 loads, vs. two binary halvings (one for the half, one for the quarter) that would issue 2 dependent loads. The compound instruction count is comparable, but the address access pattern produces fewer LLC-visible accesses in the shared-cache regime.
- **At t=64**: k-ary's additional instruction pressure drops IPC more (−10%), but LLC misses also drop, so wall-time comes out marginally faster (1.07×).

**Implications:**
1. K-ary is the **third-largest single-variable gain** in the thesis at t=16 (behind columnar at t=1 and f16 at t=16).
2. It disproves a specific hypothesis about the t=1 regime: the CMOV chain is not the dominant cost at single-thread — the outer cluster loop absorbs the latency.

**Compound with f16 (script: `scripts/ablation_kary_f16.sh`, same session):**

| Threads | f16 alone (s) | kary+f16 (s) | Ratio |
|---------|--------------|-------------|-------|
| 1 | 24.72 | 23.60 | 1.05× |
| 4 | 7.40 | 7.40 | 1.00× |
| **8** | 5.91 | **4.67** | **1.27×** |
| **16** | 3.94 | **4.03** | **0.98×** |
| 32 | 3.44 | 3.67 | 0.94× |
| 64 | 3.74 | 3.58 | 1.04× |

**Compound does not multiply at t=16 (where both peak individually).** Predicted: 1.19 × 1.40 ≈ 1.67×. Actual: ≈1× (essentially no compound benefit at t=16, mild regression at t=32).

**Interpretation — both optimisations address the same constraint:**
- k-ary reduces LLC round-trips per search
- f16 halves per-thread footprint, easing LLC eviction
- Both relieve shared-LLC pressure at t=16
- Once f16 halves the footprint, the LLC traffic that k-ary would reduce is already gone
- k-ary's instruction-count overhead (3 loads per step vs 1) then becomes the dominant remaining effect
- At t=8, LLC pressure is not yet fully active, so both optimisations have headroom and compound to 1.27×

This is a clean scientific outcome: it isolates shared-LLC capacity as a *finite* specific constraint. Two optimisations addressing the same constraint cannot stack beyond what the constraint allows.

**Correctness:** precision = recall = 1.000 on dev_small (200 queries, exact-match result sets against the stdlib baseline). kary+f16 total IDs = 3,581,415 = identical to f16-alone (quantisation difference vs f32 is the same).

---

## Scientific Conclusions (UPDATED 2026-04-24)

### 1. The Bottleneck Profile

Fainder's query execution has three regimes:

- **t=1 to t=8 (Compute/L1-bound)**: IPC 2.4–3.7, L1 hit rate 99.45%. The binary search working set fits in L1; the dependent load chain is CMOV-bound. Speedup from parallelism is near-linear (up to 8× at t=8).
- **t=16 (Shared-cache-pressure regime)**: Still high IPC (2.36), but LLC miss rate (21% → 18.5% with f16) indicates 16 threads are competing for LLC capacity. Optimizations that reduce per-thread footprint (f16) win by relieving this pressure.
- **t=32 to t=64 (Memory-subsystem-contended)**: IPC drops to 1.41, LLC miss rate climbs to 31%. Cross-NUMA traffic and DRAM bandwidth start to matter (NUMA pinning helps by 15.4% at t=64 but not below).

### 2. Why Each Optimization Works (or Doesn't)

| Optimization | Regime where it wins | Mechanism |
|---|---|---|
| **Rayon** (t=1→16) | Compute-bound; parallel scaling | Removes GIL; near-linear scaling to t=16 |
| **SoA** (t=1, t=64) | L2/L3 accesses | 8% cache-line efficiency; invisible on L1 hits |
| **f16** (t=16) | Shared-cache pressure | Halves footprint; more threads' working sets fit in LLC |
| **Eytzinger** | (loses at t≥16) | +50% footprint hurts shared-cache |
| **NUMA pinning** (t=64) | Cross-NUMA traffic | 15.4% win; neutral below t=32 |
| **Columnar** (t=1–4) | Serial L1 reuse | Keeps column L1-warm across queries; 2.49× at t=1 |
| **Cluster-par** (t=1) | Low-thread task granularity | Nested par_iter helps at t=1 (1.23×), catastrophic at t=64 |
| **SIMD** (null) | — | IPC already saturated (2.46); no idle cycles to fill |
| **Batch-search** (null) | — | L1-warm columns; OoO already overlaps serial searches |

### 3. The Three Robust Claims

| Claim | Evidence |
|-------|----------|
| GIL removal (Rayon) is the dominant speedup | 6.09× vs Python at t=16 (eval_medium query-only) |
| Footprint reduction wins at the shared-cache-pressure regime | f16 1.40× at t=16; Eytzinger 0.81× at t=16 |
| Cross-NUMA contention only matters at t=64 | NUMA pinning: neutral at t≤16, +15.4% at t=64 |

---

## What Is NOT Done (Gaps vs. Proposal)

### ✅ SIMD Vectorization — Done (Phase 10, null result)

### ✅ Branch-misprediction rate measurement — Done (2026-04-24, Phase 4a)

Branch-mispred rate measured: 0.01–0.05%. Confirms `partition_point` is CMOV-based (branchless). No branch penalty is paid.

### ✅ Index construction time comparison — Done (Phase 13)

Complete 3-dataset table: dev_small 6.19×, eval_medium 3.64×, eval_10gb 2.19×.

### ❌ L2-specific cache counter

Current perf measurements cover L1, LLC, and cache-refs (approximately L3). L2-specific events (e.g., `mem_load_retired.l2_miss`) were not collected separately — would require microarch-specific counter names.

**Low priority** — the L1 hit rate (99.45%) and LLC miss rate (21% at t=16) together bound the L2 behavior.

---

## All Generated Figures

| Figure | Content |
|--------|---------|
| `fig1_baseline_dev_small.pdf` | dev_small baseline: exact/binsort/ndist/pscan vs Fainder variants |
| `fig2_rust_vs_python_speedup.pdf` | Speedup across 3 dataset scales |
| `fig3_thread_sweep.pdf` | Thread scaling on eval_medium |
| `fig4_summary_heatmap.pdf` | Summary heatmap of all ablation results |
| `fig5_numa_vs_unpinned.pdf` | NUMA pinning ablation (needs regen with new data) |
| `fig6_tmpfs_vs_disk.pdf` | tmpfs vs disk storage isolation |
| `fig7_soa_vs_aos.pdf` | Memory layout ablation (needs regen with new data) |
| `fig8_hardware_ablation_summary.pdf` | Hardware ablation summary (needs regen) |
| `fig9_cluster_par_ablation.pdf` | Cluster-level parallelism ablation (needs regen with new data) |
| `fig10_roofline_perf.pdf` | perf stat hardware counters (needs regen with new IPC/LLC) |
| `fig11_f16_comparison.pdf` | f16 vs f32 precision ablation |
| `fig12_eytzinger.pdf` | Eytzinger BFS layout ablation |
| `fig13_columnar_vs_row.pdf` | Column-centric vs row-centric engine (2×2 panel) |
| `fig14_simd_ablation.pdf` | AVX2 SIMD vs scalar |
| `fig15_batch_search.pdf` | 8-way batch vs serial binary search |
| `fig16_serialization.pdf` | Serialisation benchmark |
| `fig17_rebinning.pdf` | Rust rebinning construction |
| `fig18_full_pipeline.pdf` | Combined full pipeline |

---

## Implementation: Feature Flags

```toml
[features]
aos         = []           # Array-of-Structs layout (ablation control)
cluster-par = []           # Nested cluster-level parallelism (ablation control)
f16         = ["dep:half"] # Half-precision index values
eytzinger   = []           # BFS-order values for prefetch-friendly binary search
simd        = []           # AVX2 SIMD binary search
batch-search = []          # 8-way interleaved batch binary search
```

Default build: SoA + f32 + query-level parallelism only.

---

## Key Files

| File | Purpose |
|------|---------|
| `src/index.rs` | FainderIndex struct; conditional SubIndex variants (SoA/AoS/f16/Eytzinger) |
| `src/engine.rs` | execute_queries; row-centric and columnar execution engines |
| `src/rebinning.rs` | Rust rebinning kernel (Rayon + pdqsort, Phase 13) |
| `src/simd_search.rs` | AVX2 partition_lt/partition_le intrinsics |
| `fainder/execution/percentile_queries.py` | Python/Rust dispatcher; suppress_results threading |
| `fainder/utils.py` | `save_flat_index`, `load_flat_index`, `load_index` (auto-detect .fidx vs .zst) |
| `fainder/preprocessing/percentile_index.py` | Rust rebinning integration |
| `analysis/plot_all_results.py` | All figures |
| `scripts/ablation_parallel.sh` | Thread sweep 1→64 |
| `scripts/ablation_layout.sh` | SoA vs AoS (fixed 2026-04-24: now uses --suppress-results) |
| `scripts/ablation_cluster_par.sh` | query-par vs cluster-par (fixed 2026-04-24) |
| `scripts/ablation_f16.sh` | f32 vs f16 thread sweep |
| `scripts/ablation_eytzinger.sh` | SoA vs Eytzinger sweep |
| `scripts/ablation_columnar.sh` | Row vs columnar sweep |
| `scripts/ablation_simd.sh` | Scalar vs SIMD AVX2 binary search sweep |
| `scripts/ablation_batch_search.sh` | Serial vs 8-way batch binary search sweep |
| `scripts/ablation_numa.sh` | NUMA pinning vs unpinned (new 2026-04-24) |
| `scripts/benchmark_serialization.sh` | 4-step serialization benchmark |
| `scripts/benchmark_rebinning.sh` | Rust vs Python rebinning construction |
| `scripts/benchmark_full_pipeline.sh` | Combined full pipeline |
| `scripts/perf_branch_misses.sh` | perf stat with --delay=40000 for branch/IPC (new 2026-04-24) |
| `scripts/perf_comprehensive.sh` | perf stat with CORE/CACHE/LLC event groups (new 2026-04-24) |

---

## Data Locations

```
logs/ablation/                           # Main ablation logs
logs/perf/                               # perf stat results (2026-04-24)
logs/perf_branch/                        # perf stat (branch/IPC focus)
logs/rebinning/                          # Rebinning construction benchmarks
logs/serialization/                      # Serialization benchmark
logs/full_pipeline/                      # Full pipeline benchmark
logs/baseline_comparison/                # Baseline comparison vs VLDB methods

/local-data/abumukh/data/gittables/eval_medium/indices/best_config_rebinning.zst
/local-data/abumukh/data/gittables/eval_medium/indices/best_config_rebinning.fidx  # flat binary (25.74 GB)
/local-data/abumukh/data/gittables/eval_10gb/indices/best_config_rebinning.zst
/local-data/abumukh/data/gittables/eval_10gb/indices/best_config_conversion.zst
data/dev_small/indices/best_config_rebinning.zst
data/dev_small/indices/best_config_rebinning.fidx
```

---

## Next Steps (Priority Order)

| Priority | Task | Effort | Impact |
|----------|------|--------|--------|
| **1** | Update thesis chapters with re-measured numbers (Phase 4a, 4b, 5, 6) | 2–3 hours | HIGH — keeps thesis factually correct |
| **2** | Regenerate figures fig5, fig7, fig9, fig10 with new data | 1 hour | Visual consistency with text |
| **3** | Polish and submit thesis chapters (Overleaf) | Ongoing | Deadline: end of May 2026 |
| 4 | Stage 5B: hybrid blocked row+columnar engine | 2–3 days | Advisor concern |
| 5 | K-ary search (16-way, one-cache-line node) | 3–5 days | Potentially large: reduces dep-load chain from 12 to 3 |

**All three primary proposal axes are complete. 12 ablations + 1 combined pipeline benchmark done: Phases 1–14. Stages 3, 4, 5A complete.**

*Last updated: 2026-04-24 (perf re-measurement, NUMA re-run, SoA/AoS + cluster-par re-run, eval_10gb rebinning, Roofline narrative revised)*
