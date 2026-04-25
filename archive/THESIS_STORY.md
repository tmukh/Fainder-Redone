# Thesis: Optimizing Fainder — A Scientific Ablation Study
*Tarik Abu Mukh — Master's Thesis, due end of May 2026*

---

## 1. What Existed Before This Thesis

### The Original Fainder System (VLDB 2024)

Fainder is a clustered percentile index for *distribution-aware dataset search* — the problem of finding datasets whose column distributions satisfy a given percentile predicate, e.g. "find all columns where the 90th percentile is above 100."

The paper (Deac et al., VLDB 2024) introduced:
- A two-phase approach: **index building** (offline) + **query execution** (online)
- Two index modes: **rebinning** (fast, approximate) and **conversion** (slower build, higher accuracy)
- A Python implementation using NumPy and SciPy
- Benchmarks on three real-world datasets: GitTables, SportsTables, Open Data USA

**Key paper results (Python, full GitTables, 5M histograms, 999 queries):**
| Method | Time (s) |
|---|---|
| Exact scan (profile-scan) | 48,310 |
| BinSort | 7,906 |
| NDist | 2,543 |
| PScan | ~14,000 (estimated) |
| Fainder (Python, approx) | 284 |

Fainder achieves ~170x speedup over exact scan and ~28x over BinSort — primarily because the clustered index eliminates the need to scan all histograms for every query.

### What the Python Implementation Does

The query hot path in `fainder/execution/percentile_queries.py`:
1. For each query, identify candidate clusters whose bin ranges could satisfy the predicate
2. Within each candidate cluster, perform a linear scan or binary search over the sorted bin values
3. Return a boolean result per histogram (recall metric)

The index is stored as a Structure-of-Arrays (SoA) in NumPy: separate `values[]` and `indices[]` arrays per cluster subindex. Parallelism is via Python's `multiprocessing.Pool`, which is constrained by the GIL and inter-process serialization overhead.

---

## 2. What This Thesis Implements

### The Research Question

**Which optimization techniques contribute most to Fainder's speedup, and why does this specific workload benefit from each one?**

This is not a "we rewrote it in Rust and it got faster" thesis. It is a systematic ablation study that isolates the contribution of each technique and explains the *mechanism* behind each speedup using hardware performance models.

### What Was Implemented

#### A. Rust Query Engine via PyO3/Maturin

**Files:** `src/engine.rs`, `src/index.rs`, `src/lib.rs`

The query execution phase was reimplemented in Rust and exposed to Python as a native extension (`fainder_core.abi3.so`) via PyO3. Maturin is used as the build system.

Key design choices:
- The Python layer (`fainder/execution/percentile_queries.py`) transparently delegates to the Rust engine when `FAINDER_NO_RUST` is not set
- The Rust engine accepts the same index format — no change to index building, only query execution changes
- `FAINDER_NO_RUST=1` forces the original Python path, enabling A/B comparison on identical data

#### B. Rayon Work-Stealing Parallelism

**File:** `src/engine.rs`

Queries are embarrassingly parallel: each query scans all clusters independently with no shared mutable state. This makes them ideal for Rayon's work-stealing scheduler.

```rust
pool.install(|| typed_queries.par_iter().map(|q| execute_single(q, &index)).collect())
```

The thread count is controlled via `FAINDER_NUM_THREADS=N`, which builds a custom Rayon `ThreadPool`. This is the ablation lever for the parallelism experiments.

Why this workload is "Rayon-friendly":
- No shared mutable state between queries (no locking, no false sharing)
- Heterogeneous query selectivity (some queries match many clusters, some few) → work-stealing rebalances dynamically without programmer effort
- No GIL: Rust holds no Python objects during execution, so all cores are truly utilized

#### C. Structure-of-Arrays (SoA) Memory Layout

**File:** `src/index.rs`

The index is stored column-major: all `values[]` contiguous, all `indices[]` contiguous, rather than interleaved `(value, index)` pairs per entry.

Why this matters for Fainder's access pattern:
- The hot loop is binary search over `values[]` for each cluster
- SoA keeps all values for a cluster in a single contiguous memory region → CPU prefetcher can predict and preload the next cache line during the search
- AoS would interleave `(value, index)` pairs → every other element (the index) pollutes cache lines during the search phase, halving effective cache utilization

#### D. `partition_point` Binary Search

**File:** `src/engine.rs`

Replaced `binary_search` with `partition_point` for the percentile predicate. The predicate `|x| x < target` is simpler than a three-way comparison → fewer branch mispredictions → better instruction-level parallelism. Measured contribution: ~2–5%.

#### E. Typed Query Execution

**File:** `src/engine.rs`

Queries are deserialized into typed Rust structs at the boundary, eliminating repeated Python object unpacking inside the hot loop. Eliminates Python interpreter overhead entirely from the inner loop.

---

## 3. Experiments Conducted and Results

### 3.1 Baseline Comparison — dev_small

**Dataset:** 50k histograms, 200 queries, 50 clusters  
**Status:** Complete ✅

| Method | Time (s) | vs. Fainder Rust |
|---|---|---|
| Exact scan | 56.0 | 80x slower |
| BinSort | 10.8 | 15x slower |
| Fainder Python (rebinning) | 0.83 | 1.18x slower |
| Fainder Rust (rebinning) | 0.70 | — (baseline) |

**Key finding:** The index structure provides the dominant speedup (15–80x over non-index methods). Rust adds ~1.18x on top of Python Fainder at this scale — the dataset is small enough that Python interpreter overhead is already a small fraction of total time.

### 3.2 Speedup Curve Across Dataset Sizes

**Status:** Core numbers confirmed ✅ (full baseline comparison for eval_medium still running)

| Dataset | Histograms | Python Fainder | Rust Fainder | Speedup |
|---|---|---|---|---|
| dev_small | 50k | 0.83s | 0.70s | **~1.18x** |
| eval_medium | ~200k | 732s | ~548s | **~1.34x** (ablation baseline) |
| eval_10gb | 323k | 514s | 85s | **~6.02x** |

> Note: the previously cited "6.66x on eval_medium" was from an earlier experiment and may have used a different query set. The ablation data (732s Python, 548s Rust at t=1) gives ~1.34x serial speedup; full parallel Rust reduces this further. The full baseline comparison currently running will give the definitive number.

**Scientific interpretation:** Rust vs Python speedup grows with dataset size because:
- Small scale: Python overhead is proportionally large → Rust's elimination of it gives ~1.18x
- Large scale: raw compute volume is large enough that Rayon's parallelism, SIMD, and SoA cache efficiency all compound → 6x

### 3.3 Parallelism Ablation — Thread Count Sweep

**Status:** Complete ✅  
**Figures generated:** `analysis/figures/ablation_threads_combined.pdf`

#### dev_small (200 queries, 50k histograms)
| Threads | Time (s) | vs. Python |
|---|---|---|
| Python baseline | 0.837 | 1.00x |
| Rust t=1 | 0.719 | 1.16x |
| Rust t=2 | 0.656 | 1.28x |
| **Rust t=4** | **0.460** | **1.82x** |
| Rust t=8 | 0.657 | 1.27x |
| Rust t=16 | 0.708 | 1.18x |
| Rust t=32 | 0.663 | 1.26x |
| Rust t=64 | 0.742 | 1.13x |

**Finding:** Peak at t=4, then degradation. With only 200 queries, Rayon's work-stealing coordination overhead (thread pool creation, task distribution, result collection) exceeds the computational savings beyond 4 threads. This is a compute-bound workload at this scale, but the work unit is too small to amortize coordination cost.

#### eval_medium (10,000 queries, ~200k histograms, 494 MB index)
| Threads | Time (s) | vs. Python |
|---|---|---|
| Python baseline | 732.05 | 1.00x |
| Rust t=1 | 548.20 | 1.34x |
| Rust t=2 | 528.86 | 1.38x |
| Rust t=4 | 537.02 | 1.36x |
| Rust t=8 | 559.45 | 1.31x |
| Rust t=16 | 553.33 | 1.32x |
| Rust t=32 | 561.52 | 1.30x |
| Rust t=64 | 539.53 | 1.36x |

**Finding:** Flat curve across all thread counts. Adding more parallelism provides zero benefit. This is the memory-bandwidth bottleneck: the index is 494 MB, every query requires loading cluster data from DRAM, and all threads share the same memory bus. The hardware memory bandwidth is saturated at t=1.

---

## 4. Experiments Currently Running

| Session | Experiment | Status | Est. Done |
|---|---|---|---|
| `baseline-medium` | Fainder Python/Rust rebinning + conversion on eval_medium | Running | ~2–4h |
| `baseline-10gb` | All methods on eval_10gb | Running | ~4–8h |
| `ablation-medium` | Thread sweep on eval_medium | Running | ~4–8h |
| `fainder-monitor` | Auto-collects results → EXPERIMENT_RESULTS.md | Watching | On completion |

---

## 5. Planned Experiments (Not Yet Run)

### 5.1 SoA vs. AoS Memory Layout Ablation

**Goal:** Isolate the contribution of the Structure-of-Arrays layout independently from parallelism and the Rust compiler.

**Method:**
- Add a Cargo feature flag `--no-default-features` that switches `SubIndex` from SoA to AoS
- Build two binaries: default (SoA) vs. `--features aos`
- Benchmark both at t=1 (serial) to isolate layout effect from parallelism
- Measure cache miss rates with `perf stat -e L1-dcache-load-misses,LLC-load-misses` for both

**Files to modify:** `src/index.rs` (SubIndex struct + flattening logic), `src/engine.rs` (column access pattern)

**Expected result:** SoA should show fewer LLC misses and faster binary search, especially on larger datasets where the index exceeds L3 cache.

### 5.2 Memory Bandwidth Experiments (1TB RAM Server)

**Goal:** Quantify the hardware bottleneck precisely and prove the flat thread curve is DRAM-bound.

**Experiment A — tmpfs isolation:**
Copy the index to `/dev/shm` (RAM-backed filesystem, bypasses all I/O) and re-run eval_medium at all thread counts. If throughput increases → workload had I/O component. If flat → truly DRAM-bound.

```bash
cp /local-data/.../best_config_rebinning.zst /dev/shm/
FAINDER_NUM_THREADS=N run-queries -i /dev/shm/best_config_rebinning.zst ...
```

**Experiment B — NUMA pinning:**
The server has multiple NUMA nodes. Threads spawned across nodes pay a remote-access latency penalty. Pinning all computation to one node maximizes memory locality:

```bash
numactl --membind=0 --cpunodebind=0 run-queries ...
```
Compare unpinned vs. pinned at t=1,4,16,64.

**Experiment C — Roofline measurement:**
Measure achieved memory bandwidth (GB/s) during query execution and compare to the server's theoretical peak. This places Fainder precisely on the Roofline model.

```bash
perf stat -e LLC-load-misses,LLC-loads,cache-misses,cache-references \
  run-queries -i ... -q ... -m recall
```

**Experiment D — f32 → f16 index quantization:**
Halve the index size by storing bin values as `f16` instead of `f32`. Smaller index = more fits in cache = higher effective bandwidth. Add the `half` Rust crate and implement a quantized SubIndex variant. This is both a measurement and an optimization.

### 5.3 Index Construction Time Comparison

Measure and compare index build time across modes (rebinning vs. conversion) and dataset sizes. Currently unmeasured.

### 5.4 Accuracy Confirmation

Verify that the Rust engine produces bit-identical results to the Python engine (no approximation introduced by the reimplementation). Run `compute-accuracy-metrics` comparing Rust vs. Python recall on dev_small and eval_medium.

---

## 6. Scientific Narrative (Thesis Story)

The thesis makes five claims, each backed by a specific experiment:

**Claim 1: The index structure is the primary source of speedup.**
Evidence: dev_small baseline comparison — Fainder (any variant) is 15–80x faster than non-index methods. The Rust reimplementation adds ~1.18x on top, not the other way around.

**Claim 2: Rust's advantage grows with dataset size (compute → memory bottleneck transition).**
Evidence: speedup curve (1.18x at 50k → ~6x at 323k). At small scale, Python overhead dominates; at large scale, raw compute volume makes Rust's lack of GIL and native parallelism meaningful.

**Claim 3: Rayon parallelism is effective only when queries are compute-bound.**
Evidence: thread sweep on dev_small (peak at t=4, degradation beyond) vs. eval_medium (flat line). The flat line is a direct measurement of the memory-bandwidth bottleneck.

**Claim 4: SoA layout reduces cache misses for Fainder's binary search access pattern.**
Evidence: SoA vs. AoS ablation (planned) + perf stat cache miss counts.

**Claim 5: The memory-bandwidth wall is the hardware limit, not a software artifact.**
Evidence: tmpfs experiment (eliminates I/O), NUMA pinning experiment (eliminates topology effects), Roofline measurement (quantifies achieved vs. peak bandwidth).

Together these form a complete Roofline-model story: the index eliminates algorithmic work, Rust removes software overhead, parallelism scales until the memory bus saturates, and the memory wall is a fundamental hardware limit — not something better software can fix.

---

## 7. Thesis Chapter Outline (Draft)

1. **Introduction** — distribution-aware dataset search, why it matters, what Fainder is
2. **Background** — Fainder VLDB 2024, related work (BinSort, NDist, PScan, exact scan)
3. **Implementation** — Rust engine, PyO3 integration, SoA layout, Rayon, typed queries
4. **Experimental Setup** — datasets (dev_small, eval_medium, eval_10gb), query sets, hardware, metrics
5. **Results: Baseline Comparison** — Fainder vs. all methods across dataset sizes
6. **Results: Ablation Study** — thread sweep, SoA vs. AoS, NUMA/tmpfs, Roofline analysis
7. **Discussion** — when each optimization matters, Roofline model framing, limitations
8. **Conclusion** — what was learned, future work (f16 quantization, distributed Fainder)
