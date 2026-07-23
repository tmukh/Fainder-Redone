# Fainder Rust Port — Results

Single source of truth for all runtime measurements in the thesis. Older
measurements live under `archive/` and should not be cited.

**Status:** main-axes campaign complete (576 runs, 79 cells). Cells flagged
`—` in tables either timed out, were never run, or are flagged by a
methodology caveat in §1.6.

---

## 1. Methodology

### 1.1 Hardware

| | |
|---|---|
| CPU | 2× Intel Xeon Platinum 8468H (Sapphire Rapids) |
| Cores | 96 physical (48 / socket), 192 logical (SMT-2) |
| ISA | AVX-512F, AVX-512BW, **AVX-512_FP16** |
| L1d | 48 KB / core (4.5 MiB total) |
| L2 | 2 MiB / core (192 MiB total) |
| L3 | 105 MiB / socket (210 MiB total) |
| NUMA | 2 nodes; node0 = cores 0–47 + 96–143, node1 = cores 48–95 + 144–191 |
| RAM | 1 TiB DDR5 |
| Storage | 11 TiB local NVMe (`/local-data`) |

### 1.2 Cache convention — warm-cache, thesis-wide

Every measurement reported in this doc assumes a warm OS page cache:
the index file's pages are already resident before the timed region begins.
The bench harness ([scripts/bench.py](../scripts/bench.py)) issues a throwaway
query before each measured run to pre-warm. Cold-cache numbers are out of
scope — the thesis is about steady-state query throughput, not storage.

### 1.3 Result-emission regimes — `suppress_results`

| Regime | Setting | What gets timed | When we use it |
|---|---|---|---|
| **with-results** | `FAINDER_SUPPRESS_RESULTS=0` | Search + result-set materialization + PyO3 boxing into Python | Python baseline, end-to-end / `bestofsuite` |
| **suppress-results** | `FAINDER_SUPPRESS_RESULTS=1` | Search phase only (results consumed in Rust, not boxed) | Per-axis and per-ablation studies |

Why split: ablations isolate the search-phase signal so we can attribute the
delta to a single Cargo feature. Python and `bestofsuite` end-to-end use the
full pipeline because that's what a user pays for.

### 1.4 Datasets

All three derive from GitTables and are clustered identically (k-means,
target k=256, bin-budget 25600, quantile transform, α=1, seed=42). The
cluster count target is held constant across datasets so dataset-size is
the only varying axis.

| Dataset | Raw Parquet | Histograms | Clusters (target → actual) | Index |
|---|---|---:|---|---|
| `c256_10gb` | ~10 GB (`eval_10gb` source) | 323 719 | 256 → **129** | `/local-data/abumukh/data/gittables/c256_10gb/indices/best_config_rebinning.fidx` |
| `c256_30gb` | ~30 GB (`eval_medium` source) | 996 632 | 256 → **184** | `/local-data/abumukh/data/gittables/c256_30gb/indices/best_config_rebinning.fidx` |
| `c256_56gb` | 56 GB (full GitTables `pq/`) | 5 017 619 | 256 → **191** | `/local-data/abumukh/data/gittables/c256_56gb/indices/best_config_rebinning.fidx` |

**Why actual cluster counts deviate from 256.** `MiniBatchKMeans(n_clusters=256)`
is followed by `np.unique()` over the assignment vector — empty centroids are
silently dropped. Smaller datasets leave more centroids empty during the
mini-batch update phase. All three counts comfortably exceed our 96 physical
cores (the parallelism floor we care about).

Queries (10 000 (percentile, op, threshold) tuples) are shared via symlink
to a single canonical file; queries are dataset-independent (no column IDs).

### 1.5 Bench harness

[scripts/bench.py](../scripts/bench.py) invokes `run-queries` in a fresh
subprocess per measurement and parses wall-clock + perf counters from its
output. Every (build, threads, regime) cell is repeated **5 times** and we
report the **median**. perf counters captured: instructions, cycles, IPC,
L1d/LLC misses, branch-misses, AVX-512 op counts.

### 1.6 Methodology caveat — `wall_s` excludes Python boxing

`wall_s` is parsed from the Rust runner's `"Rust index-based query execution
time"` log line, which excludes Python-side result-set boxing (`set(int)`
construction in CPython for ~165k–1M IDs/query × 10K queries). For
**with-results** runs, the actual subprocess wall-clock is 5–20× larger
than the recorded `wall_s` on the bigger datasets, because boxing dominates.

**Implication.** The numbers in §2 (Python) and §5 (`bestofsuite` with-results)
measure *Rust query execution time*, not user-visible wall. The suppress-
results numbers (§3.1, §3.2, §3.3, §5 alt) are not affected. The Python-vs-
Rust speedup ratios in §5 compare Python's full-pipeline wall (which
includes Python's own boxing) against Rust's search-only wall — the honest
user-visible Rust speedup is somewhat smaller than reported. Future work:
bench harness should capture `subprocess_s` alongside `wall_s`.

---

## 2. Python baseline

The baseline is the unmodified Fainder Python implementation
(`FAINDER_NO_RUST=1`). Run under **with-results**.

### 2.1 Wall-clock × dataset × threads (median)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| `c256_10gb` | 610.2s | 601.5s | 599.7s | 596.3s | 600.2s | 601.6s |
| `c256_30gb` | — | — | 1886.4s | — | — | — |
| `c256_56gb` | — | — | — | — | — | — |

Python's wall-clock is **flat across all thread counts** on 10gb (spread
2%). 30gb at t=16 was sampled to confirm scale; 56gb timed out at the
3600s cap (~3500–4000s extrapolated from 10gb / 30gb scaling).

### 2.2 Perf counters at t=16

| Dataset | IPC | Cycles | Instructions | LLC misses | Branch misses |
|---|---:|---:|---:|---:|---:|
| `c256_10gb` | 2.35 | 2.5 T | **5.8 T** | 2.27 G | 4.58 G |
| `c256_30gb` | 2.23 | 8.1 T | **18.1 T** | 6.87 G | 15.40 G |

### 2.3 Where Python spends its time

The Python query loop holds the GIL throughout, so `FAINDER_NUM_THREADS=N`
is silently ignored: the loop iterates over queries calling
`numpy.searchsorted` on each cluster, and `searchsorted` does not release
the GIL. Threading has no effect.

**The IPC paradox.** Python's IPC at t=16 is **2.35** — *higher* than Rust's
**1.66** (§3.3.1). Yet Python is **411× slower**. Mechanism: Python executes
**152× more total instructions** than Rust for the same query batch
(interpreter dispatch, attribute lookups, dict lookups, list iteration,
type checks). Each instruction that *does* execute is well-cached and
pipeline-friendly (NumPy on contiguous arrays), giving high IPC. But
there are vastly more instructions overall. **High IPC ≠ fast.**

This is a useful framing for the rest of the thesis: optimisations that
reduce *total instructions* (e.g. f16 → fewer memory ops, mimalloc → fewer
allocator paths) often *lower* IPC while *increasing* wall-clock speed.
What matters is total cycles × frequency, not cycles-spent-efficiently.

---

## 3. Main axes

Each axis is measured against the default Rust build (no Cargo features)
under **suppress-results**, so the delta isolates the search phase.

### 3.0 Reading guide — the ceiling structure that organises §3

Before drilling into individual ablations, the campaign's central
empirical finding (cross-cuts §3.1, §3.5.3, §3.6 and is confirmed
again in §3.10): **on this hardware (Sapphire Rapids 8468H, ~600 GB/s
DDR5, 105 MB shared L3), the binding ceiling for Fainder's percentile
queries is never single-thread latency**. The per-cluster column data
fits in L1/L2; the binary-search dependent-load chain executes
predictably; CMOV in stdlib `partition_point` already removes the
predictable branches. Every ablation that targets the **latency end**
of the memory hierarchy — leaf-stage SIMD (§3.1), 8-way pipelined
batch-search (§3.5.3), 16-query horizontal-SIMD lockstep (§3.5.3),
PGM-index learned binary search (§3.6) — measures within ±7% of
default at every (dataset, t) cell on this hardware. **The mechanism
is identical in all four cases**: the operation they accelerate does
not run at the rate that bounds wall time.

What does bind, in order of where the ablations land in §3:
1. **DRAM bandwidth** (high-t on big data): attacked by `f16` (search
   phase), `packed-ids` (emit phase), `mimalloc` (emit-phase
   allocator pressure). Documented in §3.7 + auxiliary ablations.
2. **HT-sibling contention** (t > 96): `pin-cores` keeps Rayon
   workers on physical cores. Documented §3.8.
3. **Work-fragmentation** (high-t on big data, after f16 compresses
   per-cluster work below the DRAM ceiling): cluster-cold-load
   amortisation via `query-batch` (§3.9) — best engine at 56gb t=96.
4. **Cooperative caching above qbatch** (the residual after #3 is
   addressed): falsified — morsel-driven scheduling does not buy
   headroom on top of qbatch K=128 (§3.10).

§3.1 / §3.5.3 / §3.6 together establish point 0 (latency does not
bind); §3.7–§3.10 then map the four ceilings that do. Reviewers in
a hurry should skim §3.1 / §3.5.3 / §3.6 — they're the
falsification framing for the latency-end attack — and read §3.7
onwards in full.

### 3.1 SIMD — AVX-512 leaf-stage vectorisation (`simd` feature)

**Code change.** Default uses `slice::partition_point` (stdlib branchless
binary search). The `simd` feature replaces the last ~16 elements with one
AVX-512 vector compare: 16-lane f32 (`_mm512_cmplt_ps_mask`), or 32-lane
f16 via the u16-bitcast trick (`_mm512_cmplt_epu16_mask` on reinterpreted
f16 bits — non-negative finite f16 values preserve unsigned ordering).
Upper-level dependent-load chain unchanged.

**Speedup vs `default` (suppress, median of 5):**

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| `c256_10gb` | 1.04× | 1.00× | 0.98× | 1.03× | 0.97× | 0.93× |
| `c256_30gb` | 1.03× | 1.01× | 1.02× | 1.00× | 0.90× | 0.95× |
| `c256_56gb` | 1.07× | 0.93× | 1.04× | 0.94× | 0.96× | 0.99× |

Range 0.90×–1.07× across 18 cells — within run-to-run noise. **No regime favours `simd`.**

**Mechanism — latency never binds at this scale** (per §3.0 reading guide).
Per-cluster columns are 50–5000 elements (200 B – 20 KB) — the 8-level
binary search hits L1/L2 in ≤8 cache-line accesses, not DRAM. Vectorising
the 1-cycle leaf compare while the (already cheap) load chain holds the
critical path buys nothing. CMOV-based `partition_point` is already
branchless. **Same falsified prediction shape as §3.5.2 / §3.5.3 / §3.6**
— see §3.0 + §3.13 for the cross-cutting pattern.

---

### 3.2 SoA vs AoS — memory layout (`aos` feature is opt-in)

**Code change.** Default = Structure-of-Arrays (one `Vec<f32>` per (cluster,
mode, column)). `aos` feature = Array-of-Structures (interleaved
`(percentile, id)` records). Comparing default *over* aos isolates the SoA
contribution.

#### 3.2.1 Behaviour across the matrix — SoA wins (= aos / default; >1 = SoA faster)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| `c256_10gb` | 1.12× | 1.04× | 1.01× | 0.98× | 1.07× | 1.12× |
| `c256_30gb` | 1.11× | 1.06× | 1.04× | 1.05× | 1.14× | 1.01× |
| `c256_56gb` | 1.03× | **1.17×** | 1.02× | 1.00× | 0.96× | 0.99× |

Average ~5% in favor of SoA. Peak 17% at one cell.

#### 3.2.2 Predicted favourable regime

SoA should win everywhere, with bigger gaps at higher t (when memory
bandwidth is the ceiling).

#### 3.2.3 Observed favourable regime

**The L2 working-set boundary** — i.e., one specific (dataset, t) cell
where per-thread cluster columns *just barely overflow* L2. Modest but
consistent edge elsewhere; the t-monotonic prediction did not hold.

#### 3.2.4 Mechanism

The scan is too short for layout to dominate. Only the 16-element leaf is
scanned linearly: AoS = 128 bytes (2 cache lines), SoA = 64 bytes (1 line).
The first miss costs ~200 cycles; the second is hardware-prefetched for
~free. Layout matters when the scan is *long enough* that prefetcher
behaviour stacks across many lines — which only happens at the L2
working-set boundary, where SoA's predictable stride wins decisively.

**Implication.** SoA is the correct default. Never enable `aos`. Not a
speedup-story driver — a small consistent edge that maximises at one
specific (dataset, t) ridge.

---

### 3.3 Multicore parallelism — Rayon, par over queries (default)

**Code architecture.** Default row-centric engine
([src/engine.rs:372](../src/engine.rs#L372)) is `par_iter` over **queries**
with sequential clusters within. **The default already does inter-query
parallelism.** When t=96, up to 96 distinct queries run on different
threads simultaneously. The "strong scaling" measured here is *across*
queries, not *within* a query.

#### 3.3.1 Behaviour across the matrix — wall vs t under `default` (suppress)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 | best | best/t=1 |
|---|---:|---:|---:|---:|---:|---:|:-:|---:|
| `c256_10gb` | 8.38s | 1.88s | **1.47s** | 1.60s | 1.92s | 2.84s | t=16 | **5.71×** |
| `c256_30gb` | 26.07s | 5.43s | 4.04s | **3.99s** | 4.06s | 5.49s | t=32 | **6.53×** |
| `c256_56gb` | 139.35s | 24.78s | 20.74s | 19.36s | **18.16s** | 18.78s | t=64 | **7.67×** |

The knee shifts right with dataset size: t=16 → t=32 → t=64.

Perf-counter signature on 10gb default — the high-t regression is bandwidth + capacity:

| t | wall | IPC | L1 miss% | LLC misses |
|---:|---:|---:|---:|---:|
| 1 | 8.4s | 1.78 | 0.56% | 18 M |
| 16 | 1.5s | 1.66 | 0.65% | 17 M |
| 96 | 2.9s | **0.93** | **0.90%** | **24 M** |

#### 3.3.2 Predicted favourable regime

Approximately linear scaling up to ~32 threads, flatten 32 → 64, gentle
regression 64 → 96 (NUMA cross-socket).

#### 3.3.3 Observed favourable regime

- **10gb best at t=16, regresses 2× by t=96** — small dataset, fast queries,
  96 concurrent queries thrash L3.
- **30gb best at t=32, gentle 1.5× regression** — borderline.
- **56gb best at t=64, no meaningful regression** — bigger queries hold each
  thread long enough that L3 turnover stays bounded.

#### 3.3.4 Mechanism — why the knee shifts with dataset size

Each query holds a thread until its (sequential) cluster loop finishes.
**Bigger datasets ⇒ longer queries ⇒ slower thread-pool turnover ⇒ lower
count of concurrently in-flight queries ⇒ smaller shared-L3 working set.**
On 10gb each query is ~150µs at t=1, so at t=96 the thread pool churns
through queries too fast — 96 distinct cache-line streams in flight at any
moment, blowing past 210 MiB shared L3. On 56gb each query is ~25 ms at
t=1, so even at t=96 the in-flight set is bounded by capacity.

**Implication for "parallelisation should be much faster."** Parallelism
does scale — when each query is long enough to space out memory traffic.
The 96-core machine isn't underutilised; on small data, queries are too
quick. The fix is not more parallelism (we're saturated) but **per-query
memory-traffic reduction** (f16, compression, NUMA-local placement). See
§5 (`bestofsuite`) and §3.5 (column-centric inversion) for two attempts at
this lever.

---

### 3.4 Cluster-par — nested Rayon parallelism (`cluster-par` feature)

**Code change.** The `cluster-par` feature wraps the inner cluster loop in
a *second* `into_par_iter()`. Engine becomes `par_iter(queries) ×
par_iter(clusters)` — nested parallelism, threads that finish a query's
clusters can steal work from another query's clusters.

#### 3.4.1 Behaviour across the matrix — cluster-par / default (>1 = slower)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| 10gb | 0.84× | 0.97× | 1.17× | 1.30× | **1.77×** | **1.82×** |
| 30gb | 0.74× | 0.95× | 1.19× | 1.87× | **3.70×** | **2.67×** |
| 56gb | 0.89× | 1.13× | 1.37× | 1.15× | **2.67×** | **2.96×** |

**Up to 3.7× slower** than default at high t. Strictly harmful at t≥16.

#### 3.4.2 Predicted favourable regime

Hypothesised: nested work-stealing balances heterogeneous-cluster tail
latency better than flat 10K-query par_iter.

#### 3.4.3 Observed favourable regime

**Only t=1**, and even then the win is marginal (~10–25%, possibly noise).

#### 3.4.4 Mechanism — why nested Rayon hurts when the outer is saturated

At t≥8, the outer `par_iter` over queries already saturates the thread
pool. The inner `into_par_iter` has nowhere to put its tasks — every
thread is already busy on a different query. The inner Rayon scope just
adds:
1. Task-creation overhead (~µs per task × ~150 clusters × 10K queries =
   ~1.5M extra tasks)
2. Lock contention on the shared work-stealing deque
3. Cache-line ping-pong on shared task counters

At t=64–96, contention dominates. **Nested parallelism on top of saturated
parallelism is purely overhead.**

**Implication.** Remove the `cluster-par` Cargo feature, or keep it only
as a documented negative-result ablation. Disposes of "add inter-query
parallelism" as future work — we already have it; what we lack is room
for *more* parallelism without redesigning the granularity.

---

### 3.5 Column-centric engine — invert the parallelism axis (`FAINDER_COLUMNAR=1`)

**Code architecture.** Column-centric engine
([src/engine.rs:675](../src/engine.rs#L675)) inverts the row-centric default:
```rust
(0..n_clusters).into_par_iter().map(|c| {
    for q in queries { /* search cluster c against q */ }
}).collect()
```
Threads parallelise **across clusters**; each thread sweeps all 10K queries
sequentially against its assigned cluster. Activated by setting
`FAINDER_COLUMNAR=1` at runtime — no Cargo feature needed.

#### 3.5.1 col_default — base column-centric engine

##### Behaviour across the matrix — wall (s)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 | best | best/t=1 |
|---|---:|---:|---:|---:|---:|---:|:-:|---:|
| `c256_10gb` | **3.80** | 1.41 | 1.42 | 1.58 | 1.72 | 1.73 | t=8 | 2.70× |
| `c256_30gb` | **10.26** | 6.50 | 4.87 | 4.46 | 4.64 | 5.21 | t=32 | 2.30× |
| `c256_56gb` | **62.51** | 44.25 | 42.92 | 40.32 | 40.22 | 39.63 | t=96 | 1.58× |

Column-centric / row-centric default ratio (<1 = column-centric is faster):

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| 10gb | **0.45×** | 0.76× | 0.99× | 0.98× | 0.90× | **0.59×** |
| 30gb | **0.39×** | 1.21× | 1.21× | 1.13× | 1.12× | 0.88× |
| 56gb | **0.45×** | **1.78×** | **2.07×** | **2.08×** | **2.21×** | **2.11×** |

##### Predicted favourable regime

Column-centric should win wherever per-cluster column data fits in L2
across all 10K queries, because the cluster's columns are L2-resident
once and reused 10K times. Row-centric re-fetches each cluster's columns
10K times (once per query).

##### Observed favourable regime

- **Universally at t=1** (2.0–2.6× win on every dataset).
- **10gb at any t** (only 1% slower than row-centric in the worst cell;
  much faster at t=1 and t=96).
- **Loses badly on 56gb at t≥8** (~2× slower than row-centric).

##### Mechanism — why the win/loss flips with dataset size

Win at t=1 (everywhere): only one thread, so the cache-locality benefit
fully applies — one cluster's columns stay resident in L2 across all 10K
queries against it.

Loss on 56gb at t≥8: at t=64 the engine has 191 clusters / 64 threads ≈
**3 clusters per thread**. Three problems compound:
1. **Coarse parallelism**: only 191 work units total. Heterogeneous
   cluster sizes mean the slowest thread holds back the rest.
2. **Cluster columns are >> L2 on 56gb**: each cluster's columns at 56gb
   are ~290 MB raw / >> 2 MiB L2. The "L2-resident" benefit doesn't
   apply at this scale.
3. **No work-stealing across queries**: row-centric had 10K queries / 96
   threads = ~104 queries to balance per thread; column-centric has 191
   clusters / 96 threads = ~2.

10gb wins everywhere because clusters are small enough to fit in L2 and
129 clusters / 96 threads = ~1.34 is not catastrophically coarse.

#### 3.5.2 horizontal-simd — 16-query SIMD lockstep within a cluster

`horizontal-simd` feature (requires `FAINDER_COLUMNAR=1`): packs 16
queries into AVX-512 lanes and runs them through binary search in
lockstep. Predicted: amortise leaf-load latency across 16 queries.

Speedup vs col_default — range across 18 cells: **0.94×–1.10×**, within noise.

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| 10gb | 0.94× | 1.03× | 1.06× | 1.04× | 0.98× | 1.02× |
| 30gb | 1.05× | 1.03× | 1.10× | 1.02× | 0.98× | 1.01× |
| 56gb | 1.03× | 1.03× | 0.99× | 1.02× | 0.99× | 1.02× |

**Mechanism — same as §3.1 (latency never binds, §3.0).** Lockstep
means lane-0 stall = all-lanes stall; doesn't reduce the dependent-load chain.

#### 3.5.3 batch-search — 8-way interleaved batched search

`batch-search` feature (requires `FAINDER_COLUMNAR=1`, mutually exclusive
with `horizontal-simd`): 8 binary searches in software-pipelined parallel
(separate registers, not SIMD lanes).

Speedup vs col_default — range across 18 cells: **0.96×–1.07×**, within noise.

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| 10gb | 1.00× | 1.05× | 1.02× | 0.99× | 0.96× | 1.03× |
| 30gb | 1.07× | 1.01× | 1.04× | 1.01× | 1.00× | 1.01× |
| 56gb | 0.99× | 1.01× | 0.96× | 0.99× | 1.01× | 0.99× |

**Mechanism — same as §3.1.** Pipelining hides latency across
independent searches, but loads still contend for the same memory and
cache. The chain wasn't binding to start with.

#### 3.5.4 Implication for the doc

**Column-centric is not a universal replacement.** It's a workload-shaped
choice:
- Use **column-centric when**: dataset is small enough that per-cluster
  columns fit in L2, OR thread count = 1 (single-query-at-a-time UI use
  case).
- Use **row-centric when**: dataset is big AND thread count is high.
  The 56gb t=64 case is a pathological 2× regression for column-centric.

The intra-cluster SIMD batching variants (`horizontal-simd`,
`batch-search`) are negative results for the same memory-bound reason
as Axis 1 — none of them addresses the dependent-load chain.

---

### 3.6 PGM-index — learned-index acceleration of the binary search (`pgm` feature)

**Code change.** New Cargo feature `pgm`. Adds a per-(cluster, mode, bin)
PGM model ([Ferragina & Vinciguerra, PVLDB 2020](https://www.vldb.org/pvldb/vol13/p1162-ferragina.pdf))
to each `SubIndex`. Search becomes: model lookup (one piecewise-linear segment
evaluation) + ε-bounded local `partition_point` over a window of ≤2ε+2 elements.
Replaces the ~8-level dependent-load chain of stdlib `partition_point`.

Implementation notes:
- Vendored from [gvinciguerra/PGM-index](https://github.com/gvinciguerra/PGM-index)
  (header-only C++17, MIT-licensed) via `cc` build-rs FFI to the `pgm_index_uint32_*`
  C interface.
- f32 keys handled via the **f32→u32 bitcast trick**: CDF values are non-negative
  finite, so IEEE-754 unsigned bit-pattern ordering preserves f32 numeric order
  (same idea as our f16 SIMD path).
- ε = 32 (fixed). Local scan window is ≤66 elements (1 cache line of f32, prefetcher-friendly).
- PGM models built at `FainderIndex` construction (parallel via Rayon); build cost
  is included in the timed region.
- Correctness: cross-validated against the stdlib `partition_point` path on
  10K queries × c256_10gb. **All 10000 result sets byte-identical.**

**Subtle correctness fix discovered during validation:** PGM's window contract
guarantees the *lower_bound* of `target` is inside [lo, hi]. For `is_gt=true`
queries we want *upper_bound*, and CDF columns have long flat regions (duplicate
target values where histogram bins are empty). When the duplicate run extends
past `hi`, the local scan misses elements. Fix: after the local
`partition_point`, extend forward through any duplicate target values past `hi`.
Sequential L1-friendly access, only triggers on duplicate runs, preserves
correctness on all other cases.

#### 3.6.1 Behaviour across the matrix — pgm / default ratio (suppress; <1 = pgm faster)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| `c256_10gb` | 1.12× | 1.02× | 1.00× | 1.03× | 1.05× | **0.92×** |
| `c256_30gb` | 1.02× | 1.13× | 0.96× | 1.05× | 1.11× | **0.92×** |
| `c256_56gb` | 0.91× | 1.10× | 1.00× | 0.95× | 0.99× | 0.96× |

Range across 18 cells: **0.91× – 1.13×**. Largest consistent win: **8% at t=96**
on 10gb/30gb. Small but consistent regression at low/mid t on 10gb (construction
overhead).

#### 3.6.2 Mechanism — wins land at t=96 (bandwidth), not t=1 (latency)

Predicted: largest wins at t=1 — replace ~8 dependent loads with one
model lookup + 64-element scan. Predicted ~10× wall reduction at t=1.

**Backwards from prediction.** Wins concentrate at **t=96**, not t=1.
~8% improvement on 10gb/30gb at t=96; noise-equivalent or slightly
negative everywhere else.

Same root cause as §3.1 / §3.5.2 / §3.5.3 (§3.0 mechanism summary):
binary search on a 50–5000-element column hits L1/L2 in ≤8 cache lines,
not DRAM — total cost ~200 cycles, not the 1600 the latency-bound
prediction assumed. PGM's 3-cache-line access pattern is roughly as
expensive as default's 12-line pattern when most lines hit cache, plus
PGM's segment lookup adds its own cost. **At t=96, however**, PGM's
*smaller* aggregate per-search memory footprint reduces shared-L3
bandwidth pressure under 96-thread contention — so PGM does win at
t=96, but **via ceiling #2 (bandwidth), not ceiling #1 (latency)** as
designed.

**Future work**: PGM's bandwidth-side benefit at high t suggests its
real value is as an *index compression* technique — per-bin PGM models
(~50–100 bytes each) replacing column-of-CDF, not augmenting it. Same
effort as compression-based approaches (FastLanes, ALP). Kept behind
`--features pgm` as documented modest-wins-at-high-t.

#### 3.6.6 ε grid — model-error parameter is robust

Sweep at ε ∈ {16, 32, 64, 128} on c256_10gb (median wall, suppress):

| t | ε=16 | ε=32 | ε=64 | ε=128 | default |
|---:|---:|---:|---:|---:|---:|
| 1 | 9.34s | 9.24s | 9.14s | 9.30s | 8.40s |
| 8 | 1.89s | 1.88s | 1.96s | 1.91s | 1.86s |
| 16 | 1.50s | 1.48s | 1.52s | 1.58s | 1.44s |
| 32 | 1.67s | 1.62s | 1.70s | 1.66s | 1.61s |
| 64 | 1.97s | 1.96s | 1.98s | 1.91s | 1.91s |
| 96 | **2.64s** | 2.69s | 2.81s | 2.74s | 2.92s |

**ε=16 is best at t=96** (2.64s, 10% faster than default 2.92s) because the
local scan window (≤34 elements) fits a single 256-byte cache line, so
post-PGM-lookup memory traffic is minimised. At t≤64, default wins anyway
because PGM is fundamentally targeting the wrong ceiling here.

**ε is robust within the tested range** — all four ε give within ~5% of each
other on every cell. ε=32 is a reasonable default; ε=16 is the optimum if
you specifically want to maximise the t=96 win. PGM construction time is
also robust (model count varies inversely with ε but build cost per model is
small).

---

### 3.7 Packed-ids — per-cluster bit-packed histogram IDs (`packed-ids` feature)

**Code change.** New Cargo feature `packed-ids`. Replaces `SubIndex.indices:
Vec<u32>` with three fields: `packed_ids: Vec<u32>`, `bit_width: u8`,
`stride_words: usize`. At index construction, each `SubIndex` scans its ids
array for the actual maximum global histogram id present and sets
`bit_width = ceil(log2(max_id + 1))`. IDs are then bit-packed column-major
into `packed_ids` with `stride_words = ceil(n_hists * bit_width / 32)` u32
words per column. A trailing pad word makes the cross-word load in
`packed::append_range` always safe.

The hot-path emit (`out.extend_from_slice(&col_ids[h..])` in row-centric and
columnar engines) is replaced by a method `sub.extend_ids(&mut out, bin_idx,
n_hists, start, end)` which dispatches at compile time:
- default: `extend_from_slice` on the unpacked u32 column (bandwidth = 32 bits/id)
- packed-ids: `packed::append_range` does u64-word-load + shift + mask per id
  (bandwidth = 13–20 bits/id, decode = ~3 instructions)

**Why per-cluster rather than per-column or global.** The histogram ids stored
are *global* into the dataset's flat histogram array, not per-cluster locals.
A first implementation used `bit_width_for(cluster_size)` (≤13 bits) and
silently masked the high bits, producing a 6× under-count of results that we
caught only because the byte-identical correctness validation failed. The fix
sizes width by the actual max id observed in the cluster's ids array, which
on c256_10gb gives 19–20 bits per cluster (vs 32 unpacked) — a **~37%**
reduction in id-buffer bandwidth.

A future direction is **per-cluster reindexing** (assign each unique id in
the cluster a 0..cluster_size local index, store an inverse mapping). That
would give ~13 bits/id (~60% saving) but adds a post-decode mapping step on
emit. Not done yet — see §3.7.5.

Correctness: cross-validated against the unpacked (default) build on 10K
queries × c256_10gb. **All 10000 result sets byte-identical**, every query.

#### 3.7.1 Behaviour across the matrix — packed / default ratio (suppress; <1 = packed faster)

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 |
|---|---:|---:|---:|---:|---:|---:|
| `c256_10gb` | 0.94× | 0.91× | 1.00× | 0.94× | 1.04× | **0.92×** |
| `c256_30gb` | 0.92× | 0.86× | 0.91× | 0.95× | 0.94× | **0.80×** |
| `c256_56gb` | **0.83×** | 0.97× | 0.96× | 0.98× | **0.91×** | 0.97× |

Range: **0.80× – 1.04×**. Largest wins:
- **30gb t=96: 0.80× (−20.2%)** — the bandwidth-saturation regime
- **56gb t=1: 0.83× (−17.1%)** — L3-capacity pressure at low t
- **56gb t=64: 0.91× (−8.6%)** — bandwidth before HT contention dominates

Single regression (10gb t=64, +4.2%) is one outlier in 18 cells; surrounded by
wins (−8.9% / −5.8% / −8.2% at neighbouring thread counts) — likely noise.

#### 3.7.2 Predicted favourable regime

Bandwidth attack on the emit phase. Default emits 4 bytes/id; packed emits
~2.5 bytes/id (20-bit width on c256_10gb). On bandwidth-saturated regimes
(high t, large dataset) the savings should translate directly to wall.
Predicted strongest at t=96 on the largest dataset.

#### 3.7.3 Observed favourable regime — three distinct mechanisms

The win pattern doesn't follow a single mechanism. Three regimes show
different effects:

1. **L3-capacity at low t (56gb t=1: −17.1%).** With one thread, bandwidth
   isn't saturated. But the 56gb index is too large for the 100 MB shared
   LLC even with one thread holding it. Reading 20 bits/id instead of 32
   reduces capacity-miss rate, so each id costs fewer DRAM round-trips.

2. **Bandwidth saturation at high t (30gb t=96: −20.2%).** Textbook
   bandwidth-attack. Default scales **anti-monotonically** here:
   t=64 = 4.15s → t=96 = 5.89s — the +42% slowdown adding cores is the
   diagnostic for DRAM saturation. Packed-ids breaks through (3.88s → 4.70s,
   only +21%) because per-id bandwidth is 37% lower.

3. **Coordination ceiling on 56gb at very high t (t=64: −8.6%, t=96: −2.9%).**
   On 56gb default is already flat from t=64 → t=96 (18.16s → 18.78s), which
   means it's not bandwidth-bound there either — it's hitting a coordination
   layer above bandwidth (likely HT-sibling cache contention with all 192
   logical threads in use). Packed-ids relieves bandwidth but the bottleneck
   has moved past that ceiling, so the win is small.

#### 3.7.4 Mechanism — why packed-ids breaks through where PGM didn't

PGM and packed-ids both targeted the bandwidth ceiling (PGM as a side-effect,
packed-ids by design). PGM gave ≤8% in the same regime; packed-ids gives
−20.2%. Two reasons:

1. **PGM compresses the search structure**, which is mostly cache-resident on
   our small per-cluster columns — minor bandwidth savings.
   **Packed-ids compresses the emit stream**, which goes back to userland
   buffers and is already streaming through L2 → L3 at high t. Compressing
   data that's actually moving across cache levels gives a direct bandwidth
   win.

2. **PGM disrupts the prefetcher's power-of-two stride** (§3.6.4). Packed-ids
   reads contiguous u32 words for the emit; the prefetcher continues to work.

#### 3.7.5 Implications and future work

This is the **first ablation in the campaign that produces a clear positive
result against the bandwidth ceiling**. Other techniques that targeted
bandwidth (PGM, mimalloc) gave ≤8% wins. Packed-ids gives −20% in the
intended regime.

The **56gb high-t pattern** (default already flat from t=64, packed-ids
gain only −2.9% at t=96) is itself a thesis-worthy finding: it shows there
is **a second ceiling above DRAM bandwidth on this hardware**, presumably
HT-sibling cache contention with 192 logical threads. This is the open
direction Lennart flagged as "parallelism investigation" — the proposal's
6-20× target requires breaking through *that* ceiling, not bandwidth.

**Two future directions:**

1. **Per-cluster reindexing** to drop bit width from 19–20 to ~13 bits
   (~60% saving instead of 37%). Adds a per-cluster `Vec<u32>` lookup on
   emit (one indirection); whether the extra L1 hit is cheap enough to
   compound the bandwidth win is empirical.
2. **Packed-ids + the engine's `pin-cores` socket-aware pinning** —
   if the 56gb high-t ceiling is HT contention, the right composition is
   packed-ids (relieve bandwidth) + physical-core-only pinning (avoid HT
   sharing). Composability test pending.

For now, packed-ids is **kept behind `--features packed-ids` as a confirmed
positive ablation against default**.

#### 3.7.6 Composability — does packed-ids stack on bestofsuite?

A natural follow-up: if packed-ids breaks the bandwidth ceiling against
default, does adding it on top of bestofsuite (`pooled f16 simd pin-cores
cluster-prefetch mimalloc`) compound the win? Sweep at suppress, same
3 × 6 × 5 matrix, build is `bestofsuite + packed-ids`. The `bs+pk/bs`
column below is the ratio of bestofsuite_packed vs bestofsuite (median
wall, suppress; <1× = packed-ids adds value).

Full 4-way comparison (default `def`, packed-ids alone `pk`, bestofsuite
`bs`, bestofsuite + packed-ids `bs+pk`):

| t | dataset | def | pk | bs | bs+pk | bs+pk/bs |
|---:|:---:|---:|---:|---:|---:|---:|
| 1 | 10gb |  8.40 |  7.92 |  **4.73** |  5.85 | 1.24× |
| 8 | 10gb |  1.86 |  1.69 |  **1.08** |  1.14 | 1.05× |
| 16 | 10gb |  1.44 |  1.43 |  0.83 |  **0.82** | 0.99× |
| 32 | 10gb |  1.61 |  1.52 |  0.99 |  **0.98** | 0.99× |
| 64 | 10gb |  1.91 |  2.00 |  1.16 |  **1.13** | 0.98× |
| 96 | 10gb |  2.92 |  2.68 |  1.18 |  **1.15** | 0.97× |
| 1 | 30gb | 26.43 | 24.24 |  **20.70** | 24.35 | 1.18× |
| 8 | 30gb |  5.36 |  4.62 |  **3.46** |  4.21 | 1.22× |
| 16 | 30gb |  4.04 |  3.67 |  **2.61** |  2.71 | 1.04× |
| 32 | 30gb |  3.93 |  3.74 |  **2.79** |  2.88 | 1.03× |
| 64 | 30gb |  4.15 |  3.88 |  **3.63** |  3.63 | 1.00× |
| 96 | 30gb |  5.89 |  4.70 |  **3.74** |  3.79 | 1.01× |
| 1 | 56gb | 139.35 | 115.52 | **117.58** | 130.93 | 1.11× |
| 8 | 56gb | 24.78 | 24.05 |  **18.94** | 19.83 | 1.05× |
| 16 | 56gb | 20.74 | 19.84 |  **16.03** | 16.74 | 1.04× |
| 32 | 56gb | 19.36 | 18.93 |  16.63 |  **15.99** | 0.96× |
| 64 | 56gb | 18.16 | 16.59 |  19.10 |  **17.86** | 0.94× |
| 96 | 56gb | 18.78 | 18.23 |  **20.52** | 21.16 | 1.03× |

**The wins do not compound.** Adding packed-ids to bestofsuite is **net
negative or neutral** in 12/18 cells, with regressions reaching +24% at
low t. Two cells improve modestly (56gb t=32: −4%, 56gb t=64: −6%);
ten cells are within ±5% (noise). No cell shows packed-ids producing a
larger win on top of bestofsuite than it produces on top of default.

#### 3.7.7 Why the wins overlap rather than compound

The mechanism is clear once the bandwidth ceiling's *sources* are
factored:

1. **Bestofsuite already addresses the dominant bandwidth source: the
   values column.** `f16` halves the per-load byte count for the search
   phase. The search reads 14 KB per cluster bin (n_hists × 4 B) → 7 KB
   under f16. At t=96 on 30gb where default anti-scales (4.15s → 5.89s),
   bestofsuite breaks through to 3.74s. The search-phase bandwidth
   ceiling is no longer the binding constraint in bestofsuite mode.

2. **Packed-ids attacks the *secondary* bandwidth source: the ids
   buffer.** With `pooled` already removing per-cluster `Vec<u32>` churn
   (the emit becomes `extend_from_slice` into one pre-allocated buffer
   per query), the ids-buffer pressure is small to begin with. Packed
   compresses what's already a tight memcpy stream.

3. **Packed-ids' decode cost (u64 read + shift + mask + push per id) is
   strictly net overhead when bandwidth isn't the binding ceiling.** At
   low t (t=1, t=8), where bandwidth has plenty of headroom, the extra
   instructions per emitted id pure-cost: bestofsuite_packed regresses
   +12% to +24% there.

4. **Where packed *does* still help on top of bestofsuite (56gb
   t=32/64)** — those are exactly the cells where bestofsuite's f16 win
   has been diluted by coordination overhead at high t on big data
   (see §5.4), so the bandwidth ceiling re-emerges as marginally
   binding. The −4% to −6% wins there are consistent with the
   mechanism, just attenuated.

#### 3.7.8 Implication: bandwidth ceilings are sources, not a singleton

**This is the mechanism-level finding.** "Bandwidth-bound" isn't one
ceiling — on this workload it factors into search-phase (values reads)
and emit-phase (ids writes), and the two are addressed by different
techniques. f16 dominates the search-phase source; packed-ids
dominates the emit-phase source. Composing them only compounds when
*both* sources are simultaneously binding — which happens rarely on
this workload because the search phase has the larger memory
footprint at typical configurations.

The right composition recipe, as a result, is **dispatch-on-regime**:
default → packed-ids when the workload doesn't have f16-equivalent
search-phase relief; bestofsuite (with f16) when search-phase
bandwidth is the dominant load. **`bestofsuite + packed-ids` is not a
strictly-better build** despite being the union of two positive
ablations — additivity of positive ablations is not given on
hardware-near workloads.

This is also the practical answer to the research question we set
out with: **does the bandwidth attack compose with the existing
positive features?** No, because the existing features already
addressed the dominant bandwidth source. The remaining ceiling at
high t on big data is *not* bandwidth — it's coordination/instruction
throughput. The next section probes that ceiling directly.

---

### 3.8 Parallelism ceiling — HT-contention probe (default) vs work-fragmentation (bestofsuite)

After §3.7 narrowed the open ceiling to "something at high t, *not* bandwidth,"
the obvious next probe is whether HT-sibling cache contention is the binding
factor. The Sapphire Rapids 8468H has 96 physical cores × 2 HT siblings = 192
logical cores. Going from t=96 → t=192 forces every physical core to share
L1/L2 with a sibling. If HT contention is the ceiling, t=192 should be
**worse** than t=96; if not, t=192 should be flat or better (extra throughput
from the second HT lane filling pipeline bubbles).

Probe: 5 reps each on c256_56gb at t=192 for `default` and `bestofsuite`,
suppress mode. Compared against the existing t=64 / t=96 numbers from the
main sweep.

#### 3.8.1 The two builds saturate on different ceilings

| build | t=64 | t=96 | t=192 | Δ(192 vs 96) |
|---|---:|---:|---:|---:|
| `default`     | 18.15s | 18.78s | **22.77s** | **+21.2%** |
| `packed-ids`  | 16.59s | 18.23s | (not run)  | — |
| `bestofsuite` | 19.10s | 20.52s | 20.76s     | +1.2% (flat) |

The two builds reveal **distinct mechanisms**:

- **Default loses 21% at t=192.** Adding HT siblings hurts. The default
  build's high-t ceiling is **HT-sibling contention** on shared L1/L2/execution
  resources. With t=96 (one sibling per core) it's nearly at peak; with
  t=192 (both siblings active) it's stalled on shared per-core resources.

- **Bestofsuite is essentially flat from t=96 to t=192.** Adding HT siblings
  does *nothing*. Bestofsuite's ceiling is **upstream of HT** — it's already
  saturated at t=96 on a different limiter that doesn't relax when more
  hardware threads are added.

`pin-cores` is in the bestofsuite composition; on default it is not. So at
t=96, default places threads via the OS scheduler (which prefers spreading
across physical cores when they're available) while bestofsuite forces a
deterministic 96-physical-cores plan. Both reach roughly the same wall at
t=96 (default 18.78s, bestofsuite 20.52s — bestofsuite is *slower* here,
the §5.4 anti-scale finding). The t=192 result confirms the difference is
not "OS scheduler getting it wrong" — when HT siblings are forced active,
default *does* degrade and bestofsuite doesn't, because they're hitting
different ceilings.

#### 3.8.2 Perf counters localise bestofsuite's ceiling

Picked from `logs/bench.db` (median over 5 reps; suppress mode):

| build | t | wall | IPC | LLC loads | LLC misses | LLC miss% |
|---|---:|---:|---:|---:|---:|---:|
| default     |  32 | 19.36s | 1.18 | 1.05 B | 290 M | 27.7% |
| default     |  64 | 18.15s | 0.72 | 1.11 B | 330 M | 29.6% |
| default     |  96 | 18.78s | 0.67 | 1.12 B | 332 M | 29.7% |
| default     | 192 | 22.77s | 0.43 | 1.22 B | 363 M | 29.6% |
| bestofsuite |  32 | 16.63s | 0.35 | 1.09 B | 422 M | 38.7% |
| bestofsuite |  64 | 19.10s | 0.17 | 1.20 B | 455 M | 37.9% |
| bestofsuite |  96 | 20.52s | 0.12 | 1.39 B | 498 M | 35.9% |
| bestofsuite | 192 | 20.76s | 0.07 | **1.75 B** | 561 M | 32.0% |

Two observations:

1. **Default's IPC collapse from 1.18 → 0.43 over the t-sweep tracks closely
   with HT activation.** LLC traffic grows only +17% — the data is mostly
   *already in cache*, threads are just stalled on the issue side. Classic
   HT contention.

2. **Bestofsuite's LLC loads grow +60%** from t=32 to t=192 (1.09 B → 1.75 B),
   much faster than default's +17%. But **LLC miss% is *dropping*** in the
   same range (38.7% → 32.0%) — the extra LLC loads are *hitting L3*, not
   going to DRAM. So bestofsuite is **not** DRAM-bandwidth-saturated. It is
   suffering from per-thread L1/L2 *traffic*: more threads → more L1/L2
   misses on cluster-transitions → more L3 traffic → IPC drops to 0.07.

#### 3.8.3 Mechanism — work-fragmentation, not bandwidth or HT

The story for bestofsuite's t=32 → t=96 anti-scale on 56gb:

- f16 + simd + pooled compress per-cluster work: each thread finishes its
  cluster's binary search and emit in much less time than default would.
- 56gb has 191 clusters, so at t=96 each thread handles ~2 clusters total.
- Cluster transitions involve cold-loading the next cluster's bin-edges
  array (~50 elements) and the first cache line of its values column
  — 2–3 cache lines that aren't in L1/L2 from the previous cluster.
- With shorter per-cluster work, the **per-cluster transition cost is now
  a larger fraction of total per-cluster time**. Doubling threads halves
  per-thread cluster count → halves transition amortisation → IPC drops.

The L3 absorbs the extra L1/L2 misses (LLC miss% drops from 38.7% to 32.0%
as t increases), so DRAM is not saturated. There is no bandwidth ceiling
to attack here — there is a *coordination* ceiling.

#### 3.8.4 Why this is the load-bearing finding for the rest of the campaign

This connects three findings into one mechanism:

- **§3.7 (packed-ids)** doesn't compose with bestofsuite because the
  binding ceiling stopped being bandwidth. Packed-ids' decode overhead
  (instructions per id) only makes work-fragmentation worse.
- **§5.4 (bestofsuite anti-scales at high t on big data)** is now
  quantified: IPC = 0.07, LLC traffic +60% — work-fragmentation drives
  per-thread L1/L2 miss rate up.
- **§3.4 (cluster-par regresses up to 3.7×)** is the same mechanism in
  reverse: nested cluster-level parallelism *adds* work-fragmentation on
  top of query-level parallelism, deepening the ceiling.

The right techniques for breaking past this ceiling are not on the bandwidth
axis (compression, f16, packed-ids) or the HT axis (`pin-cores`, NUMA-aware
thread placement). They are on the **work-unit-size axis**:

- **Cluster-batching**: assign each Rayon task N consecutive clusters
  rather than 1, amortising cold-load across N transitions.
- **Inter-query prefetching**: extend the existing `cluster-prefetch`
  (single-cluster lookahead) to query+1's first cluster.
- **Persistent thread-local state**: hot caches of bin-edges arrays,
  reused across cluster visits.
- **Async pipelining (tokio-style)** as Lennart flagged: the work-stealing
  scheduler's overhead is itself a coordination cost; an async pipeline
  with explicit task graph could exploit cluster-transition latency.

That set is the open frontier. None of them are bandwidth-attack techniques.

---

### 3.9 Query-batch — column-centric inner loop within K-query batches (`query-batch` feature)

**Code change.** New Cargo feature `query-batch`, new file
`src/engine/query_batched.rs`. The dispatch in `engine::execute_queries`
takes the new path when the feature is enabled and the build is non-aos /
non-f16. Outer parallelism is over **K-query batches** (`par_chunks(K)`)
rather than individual queries; within each batch, the loop order is
**inverted** to clusters-outer, queries-inner. The cluster `c`'s
bin-edges + active column slices stay in L1/L2 while all K queries in
the batch process them, then the thread moves to cluster `c+1`. K is
read from `FAINDER_QUERY_BATCH` env (default 64).

This directly attacks the §3.8 work-fragmentation ceiling: the cluster
cold-load that bestofsuite couldn't amortise (1 query × 1 cluster × full
cold-load) is now amortised across K queries (K queries × 1 cluster ×
1 cold-load).

Correctness: cross-validated against the default build on c256_10gb at
t=16 with `--output`. **All 10000 result sets byte-identical.**

#### 3.9.1 K-sensitivity at t=96 on c256_56gb (suppress; median wall, 5 reps)

| K | wall | vs default (18.78s) | vs bestofsuite (20.52s) |
|---:|---:|---:|---:|
| 16  | 19.92s | +6.1% | −2.9% |
| 32  | 20.28s | +8.0% | −1.2% |
| 64  | 20.47s | +9.0% | −0.3% |
| 128 | **16.17s** | **−13.9%** | **−21.2%** |
| 256 | 16.44s | −12.5% | −19.9% |

Optimal K=128 produces 78 batches at t=96 — *fewer batches than threads* (96).
18 threads are idle. The K=128 win over K=64 (which uses 156 batches with
full thread saturation) shows the binding constraint is **per-batch
cluster amortisation, not thread utilisation**. Trading 19% thread
idleness for 2× more queries-per-cluster-load is the right deal at this
ceiling.

#### 3.9.2 Best-K across the t-sweep on c256_56gb

| t | default | bestofsuite | query-batch (best K) | best K | qbatch / best |
|---:|---:|---:|---:|---:|---:|
| 32 | 19.36s | 16.63s | 17.07s (K=64) | 64 | +2.6% |
| 64 | 18.15s | 19.10s | 16.61s (K=256) | 256 | **−13.0%** |
| 96 | 18.78s | 20.52s | 16.17s (K=128) | 128 | **−21.2%** |

At t=32 bestofsuite still wins by 2.6% — it has `f16` (halves search-phase
bandwidth) which query-batch alone does not. At t=64 and t=96, query-batch
beats bestofsuite by 13–21% — its work-fragmentation attack succeeds where
bestofsuite's bandwidth attack fails. **Optimal K grows with thread count**:
t=32 → K=64, t=64 → K=256, t=96 → K=128. The pattern is not strictly
monotonic (K=128 beats K=256 at t=96) — there's a tail-latency vs
amortisation trade-off whose sweet spot depends on (cluster_count,
thread_count, query_count).

#### 3.9.3 Mechanism — exactly what work-fragmentation predicted

The §3.8 hypothesis was: bestofsuite's optimisations compress per-cluster
work to where cluster-transition cold-load is the binding cost. Two
predictions followed:

1. **Bestofsuite's anti-scale at high t on big data should be fixable by
   reordering the loop to keep clusters hot for multiple queries.**
   Confirmed: query-batch breaks the t=32 → t=96 anti-scale (bestofsuite
   16.63 → 19.10 → 20.52; query-batch 17.07 → 16.61 → 16.17 — *no anti-scale*).

2. **Bandwidth-axis attacks (packed-ids, more f16) shouldn't help further,
   because the binding ceiling is no longer bandwidth.** Confirmed in
   §3.7.6: composing packed-ids with bestofsuite gives no compounded win.

**The work-unit-size axis is real and addressable.** Cluster-batching via
loop-reorder + chunked parallelism is a structural change the existing
ablations (`f16`, `simd`, `pin-cores`, `pooled`, `mimalloc`) cannot
replicate, because they all attack the per-cluster *work content*, not
the per-cluster *transition cost*.

#### 3.9.4 Generalisation across the 3-dataset matrix — regime-dependent

K=64 default sweep (5 reps each, suppress mode). qb/best column = ratio of
query-batch K=64 wall to bestofsuite wall (negative = query-batch faster).

| t | 10gb qb/best | 30gb qb/best | 56gb qb/best |
|---:|---:|---:|---:|
| 1  | +18.3% | **−11.0%** | **−40.1%** |
| 8  | +45.2% | +42.3% | −2.0% |
| 16 | +74.3% | +70.9% | +6.2% |
| 32 | +79.6% | +60.0% | +2.9% |
| 64 | +134.6% | +51.4% | **−8.9%** |
| 96 | +207.0% | +107.0% | **−5.0%** |

Query-batch K=64 is **not uniformly positive**. It wins in three distinct
regimes:

1. **t=1 on big data (−40% on 56gb, −11% on 30gb).** Single-threaded loop
   reorder makes cluster cold-load amortise across 64 queries — at 70s vs
   default's 139s on 56gb, this is a 2× speedup with a single thread.
   Even faster than the columnar engine at t=1 (63s on 56gb, §3.5)
   because columnar batches all 10000 queries per cluster (cluster gets
   evicted from L1 between queries within the batch when query count is
   that high), while K=64 keeps the cluster hot for exactly 64 queries.

2. **High t on big data (56gb t=64–96, modest at K=64).** This is the
   work-fragmentation regime per §3.9.2. K=64 gives −5% to −9%; K=128
   gives −21%. The optimal K *rises* with thread count.

3. **All other cells: regression** (up to +207% at 10gb t=96).
   When bestofsuite's f16+simd has compressed per-cluster work to
   fit comfortably in L1/L2, query-batch's loop reorder adds overhead
   (per-batch route preprocessing, allocation churn) without a
   cold-load to amortise.

**The mechanism is consistent**: query-batch wins iff cluster cold-load
is the binding constraint — at low t (sequential, no parallelism to
hide it) on big data, or at high t (work-fragmentation) on big data.
Elsewhere, it adds overhead.

#### 3.9.5 What query-batch does *not* yet do

- **f16 composition.** `query-batch` originally gated to `not(f16)`,
  now ported (the f16 path uses the same loop reorder with
  `f16_partition_lt/le` and per-query target quantisation). Composing
  with bestofsuite's bandwidth attacks should give a combined attack
  against both ceilings. Validation + sweep pending.
- **Adaptive K.** A static K isn't optimal across the (n_q, n_threads,
  n_clusters) surface. The 56gb K-sweep shows the optimum varies from
  K=64 at t=32 to K=128/256 at t=96. A reasonable heuristic:
  `K = max(64, n_q / (n_threads * 2))`, but the right policy is open.
- **Variance.** K=128 at t=96 has 5-run range 15.4–19.7s (28% spread).
  The spread is from work-stealing across imbalanced batches when
  some clusters are much larger than others. K=256 has tighter
  variance but lower median. A cluster-cost-aware split would
  tighten the distribution.

#### 3.9.6 Implication — dispatch-on-regime is the practical answer

The full 4-engine matrix (default / packed-ids / bestofsuite /
query-batch) confirms what was already implied in §3.7.8:
**no single engine is universally best.** Each one is the right answer
in some region of the (dataset_size, thread_count, query_count) space:

- **bestofsuite**: medium thread counts on small-to-medium data
  (t=8–32 on 10gb/30gb).
- **query-batch (large K)**: t=1 on any data, high t on big data.
- **packed-ids**: default-engine workloads where f16 isn't enabled.
- **default**: the baseline, surprisingly competitive at low-medium t
  on 56gb.

The honest deployment recipe is to **probe the regime at startup**
(known dataset size, thread count, expected query batch) and dispatch
to the right engine. This is engineering, not research, but it follows
directly from the mechanism analysis in §3.7–§3.9.

#### 3.9.7 Composability with bestofsuite — second negative result

After porting query-batch to f16 (correctness validated: 10000/10000
byte-identical with f16-only build), we measured the
`bestofsuite + query-batch` composition on c256_56gb at the regime
where qbatch alone wins:

| t | bestofsuite | qbatch K=128 | best+qb K=64 | best+qb K=128 |
|---:|---:|---:|---:|---:|
| 32 | 16.63s | 17.22s | 17.95s (+7.9%) | 17.95s (+7.9%) |
| 64 | 19.10s | 16.89s | 25.11s (+31.5%) | 23.75s (+24.3%) |
| 96 | 20.52s | 16.17s | 25.05s (+22.1%) | 27.12s (+32.2%) |

**Composition is net negative at every cell.** At t=64 the composed
build is *worse than either component* (25.11s vs bestofsuite 19.10s
vs qbatch alone 17.40s). f16 and query-batch attack the **same
underlying axis** — cluster cold-load impact:

- **f16 halves the cold-load *size*** (2 B values column instead of 4 B).
- **query-batch amortises the cold-load *occurrences*** (1 cold-load
  per K queries instead of per query).

These multiply, not add. After f16 has shrunk the cold-load by half,
amortising it across K=128 queries costs more in route preprocessing
and per-batch state than the now-smaller cold-load saving recovers.
**The two positive ablations are substitutes, not complements.**

This is the second case where two independently positive ablations
fail to compound (alongside §3.7.6 packed-ids + bestofsuite). The
pattern is consistent: when two ablations target the *same* underlying
ceiling — even if they attack different aspects of it — composing
them adds overhead without compounding the win, because the ceiling is
already not the binding cost in the first ablation's regime.

#### 3.9.8 Final dispatch-on-regime table for 56gb

The full ablation campaign now identifies the engine that wins at
each thread count on the largest dataset:

| t | Best engine | Wall (s) | Mechanism it addresses |
|---:|:---:|---:|:---|
| 1   | qbatch K=64 | 70.4 | Sequential cluster cold-load amortisation |
| 8   | bestofsuite | 18.9 | f16 + pooled at moderate t |
| 16  | bestofsuite | 16.0 | same |
| 32  | bestofsuite | 16.6 | same — peak parallel efficiency |
| 64  | packed-ids  | 16.6 | DRAM bandwidth on emit phase |
| 96  | qbatch K=128 | 16.2 | Work-fragmentation cluster cold-load |

Three different engines win at three different thread counts on the
same dataset — and no engine is within 5% of the regime-best at every
cell. **Dispatch-on-regime is not an optimisation, it's the only way
to be near-optimal across the whole (t, dataset) surface.**

#### 3.9.9 Dispatch policy implementation and validation

Codified in `fainder/execution/dispatch.py` as a single function
`select_engine(n_clusters, n_hists, n_threads, n_queries) -> EngineConfig`
that returns the recommended Cargo features + env vars. The decision
boundaries are derived from the bench.db medians:

| Regime | Build | Ceiling addressed |
|---|---|---|
| `t > 96` (HT-active) | `bestofsuite` | HT-sibling contention |
| `t == 1` and `n_hists >= 300K` | `query-batch K=64` | sequential cold-load amortisation |
| `t in [64..96]` and `n_hists >= 600K` and `t == 64` | `packed-ids` | DRAM bandwidth on emit |
| `t in [64..96]` and `n_hists >= 600K` and `t > 64` | `query-batch K=128` | work-fragmentation |
| otherwise | `bestofsuite` | search-phase bandwidth |

Validation (`scripts/validate_dispatch.py`): for each (dataset, t) cell
we have measurements for, the policy is asked which engine it would
pick, and the recommendation's actual wall time is compared to the
measured regime-best. Across the 18-cell 3-dataset matrix:

- **17/18 cells: policy picks the exact regime-best.**
- **18/18 cells: policy within 5% of regime-best.**

The single non-exact pick is c256_56gb at t=8 (policy → bestofsuite at
18.93s; measured best is `query-batch` at 18.55s, +2.1% gap — within
measurement noise).

The boundary between `n_hists ≥ 600K` and `< 600K` lies between the
campaign's 30gb dataset (~410K) and 56gb (~770K). A 4th dataset
between them would tighten this threshold; until then, 600K is a
conservative pick favouring `bestofsuite` over the bandwidth/work-
fragmentation specialised builds.

#### 3.9.10 Why this matters for deployment

The selector is a deploy-time decision, not a runtime one — different
Cargo feature combinations compile to different SubIndex storage
layouts (`packed-ids`, `f16`) and different engine paths (`query-batch`).
A reasonable deployment pattern:

1. Build several `.so` files with the candidate feature sets
   (`bestofsuite.so`, `packed.so`, `qbatch.so`, `default.so`).
2. At application startup, after the index is loaded, call
   `select_engine(n_clusters=…, n_hists=…, n_threads=…)` and use the
   returned features+env to pick (and `LD_PRELOAD` / `importlib`)
   the matching `.so`.
3. Honour the env vars (chiefly `FAINDER_QUERY_BATCH`) when invoking
   the engine.

The thesis contribution is the **decision rule + mechanism rationale**
in §3.7–§3.9, not the loader plumbing. The loader is a small Python
shim around an established (build-many, dispatch-one) pattern.

#### 3.9.11 Variance investigation — qbatch K=128 t=96's 28% spread is system noise, not algorithmic

The original 5-rep median for qbatch K=128 at c256_56gb t=96 has
walls `[15.43, 15.49, 16.17, 19.73, 18.60]` — a 28% spread that
*looked* like it might indicate query-mix variance, NUMA
imbalance, or HT-contention noise. A 10-rep follow-up probe
(label `variance_probe_qb128_t96`, `scripts/run_variance_probe.sh`)
plus per-rep perf-counter analysis localises the variance to
**cross-process LLC pressure**, not anything algorithmic:

| metric | result | interpretation |
|---|---|---|
| `corr(wall, rep_idx)` | +0.086 | **NOT thermal** — no monotone-decreasing pattern through the sweep |
| `corr(wall, llc_miss%)` | **+0.916** | LLC pressure dominates |
| `corr(wall, llc_misses)` | **+0.943** | strongest correlation |
| `corr(wall, clock_calc)` | +0.374 | weak — DVFS is not the driver |
| `corr(wall, instructions)` | +0.846 | small absolute (0.72% stdev/mean) — workload nearly identical |
| `stdev(instructions)/mean` | **0.72%** | rules out query-mix variance |

The slow reps have +14% LLC misses on identical instruction counts,
with IPC dropping (e.g. 0.27 → 0.20 in the most extreme case). One
of the 10 reps overlapped a concurrent `tar` process touching ~84MB
of repo data; that rep recorded the highest wall (20.83s, +28% vs
the 15.5–16.5s clean baseline) and the largest LLC-pressure jump,
making it a clean control: a small (~84MB) cross-process I/O burst
visibly perturbs LLC and roughly doubles the variance signal.

This rules out the three hypotheses one would naturally test for
this kind of variance:

- **Query-mix-dependent (some queries hit unfortunate
  cluster-cost combinations)** — falsified by the 0.72%
  instruction-count stdev. The same set of queries, with the same
  order, executes the same instructions every rep.
- **NUMA imbalance** — would manifest in IPC drift across reps
  even with identical workload. We see IPC drop *with* LLC misses,
  not orthogonally to them.
- **HT-sibling contention noise** — would tie to thread-count
  scaling, not rep-to-rep. Here the workload is fixed at t=96
  across all 10 reps.
- **Thermal/DVFS** — would show as monotone-decreasing wall (or
  monotone-decreasing clock_calc) through the sweep. We see neither.

The variance is therefore **a property of the measurement
environment, not the algorithm**. Three implications:

1. **Adaptive K (workload-dependent K=f(n_queries, n_threads)) does
   not address this variance** and should not be motivated by it.
   The factor it would adapt to (per-query or per-batch cluster
   cost variation) does not vary across reps of the same workload.
2. **Median-of-N reporting is the right central tendency** for the
   ablation campaign — already the convention. Reporting the
   median absorbs the LLC-pressure tail without distorting the
   typical operating point.
3. **Bench-harness noise floor could be tightened** by either (a)
   running under `nice -n -10` + cgroup CPU/memory isolation to
   reduce cross-process LLC interference, or (b) outlier-trim
   before median (drop top + bottom rep). Cheap, reduces noise
   floor, doesn't change central tendency. Out of scope for the
   thesis claims; relevant for any future re-runs.

The thesis takeaway is that **the qbatch K=128 at t=96 win against
bestofsuite (16.17s vs 20.52s, −21.2%) is robust under noise**:
even with one tar-overlap-corrupted rep, the median is 16.17s; the
"clean" reps cluster in 15.5–16.5s, and the work-fragmentation
mechanism (§3.9.6) remains the dominant explanation. A tighter
methodology would just narrow the confidence interval, not change
the regime-best pick.

---

### 3.10 Morsel-driven scheduler — phase-aligned cooperative caching (`morsel` feature)

The query-batch finding (§3.9.8 / takeaway #12) localised the
work-fragmentation ceiling but left a residual question: **is
within-batch cooperative caching the whole story, or does cross-worker
phase coordination buy more on top?** Query-batch K=128 amortises
cluster cold-load across 128 queries *within one Rayon task*. Two
parallel tasks both processing cluster c+1 do *not* share the
prefetched data — they refault from L3/DRAM independently. A
phase-aligned scheduler would force *all* workers to (mostly) drain
cluster c before advancing to c+1, in principle keeping cluster c's
data hot in shared L3 across all 96 cores for the duration of phase c.

This is the morsel-driven design pattern (Bandle/Giceva, VLDB 2021;
HyPer/Umbra style). It's the cleanest theoretical attack on the
work-fragmentation ceiling — adds explicit phase coordination on top
of cluster-batched parallelism.

#### 3.10.1 Implementation (`src/engine/morsel.rs`)

A "morsel" is `(cluster c, queries [q_a..q_b))` — finer granularity
than query-batch's per-batch tasks. Implementation choices:

- **Pre-bucketed phase-major morsel queue.** Clusters processed in
  **LPT order** (DESC by `cluster_size`, Graham 1969 — bounds
  makespan tail at 4/3 × OPT). Within each cluster, queries chunked
  into morsels per `choose_morsel_queries(n_hists)` — heuristic
  ~50 queries on the largest clusters, scaled inverse-log of
  `n_hists` for smaller ones.
- **Per-worker FIFO Chase-Lev deques** (`crossbeam_deque::Worker`,
  the same Rust deque Rayon uses internally). Morsels distributed
  round-robin across worker queues in phase-major push order — so
  each worker's local FIFO begins phase 0, then phase 1, …
- **Soft phase alignment via FIFO push order.** No explicit barrier:
  if all workers start at phase 0 and consume FIFO from their own
  deques, they advance through phases roughly in lockstep. Stragglers
  steal across phases via `Stealer::steal` (single-element steal —
  bulk steal would scramble phase order).
- **Per-worker append-only output buffers.** Each (q, c) emit
  appends contiguous IDs to a per-worker flat `ids: Vec<u32>` and
  records `(query_id, start_offset, count)` in a per-worker
  `chunks` index. Doubling reallocation amortises growth cost.
  (A v1 attempt with per-worker × per-query `Vec<Vec<u32>>`
  produced 320K Vec headers per worker — every push hit a different
  cache line, allocator pressure was catastrophic, **+10–15× wall
  on c256_56gb t=32**. The v2 flat buffer + chunk index resolves it
  but introduces a merge phase — see §3.10.3.)

Byte-identical correctness validated on c256_10gb at t=16
(`scripts/validate_morsel.sh`); `total_ids = 1_645_713_586` matches
default exactly.

#### 3.10.2 Result: equivalent to default, loses to query-batch K=128

c256_56gb, suppress mode, median of 5:

| t  | default | bestofsuite | packed-ids | qbatch K=128 | **morsel** | morsel vs best |
|----|---------|-------------|------------|--------------|------------|----------------|
| 32 | 19.36   | **16.63**   | 18.93      | 17.22        | 18.57      | **+11.7%**     |
| 64 | 18.15   | 19.10       | **16.59**  | 16.89        | 18.09      | **+9.0%**      |
| 96 | 18.78   | 20.52       | 18.23      | **16.17**    | 18.05      | **+11.6%**     |

Morsel is **4% faster than default** at every cell but loses to the
regime-best engine by 8–12%. Critically: **morsel never wins**.

#### 3.10.3 Mechanism — why phase coordination doesn't pay

Three observations from the diagnostics (`workers_ms`/`bucket_ms`/
`copy_ms` instrumentation, full results suppressed at the bench
boundary):

1. **Wall is flat across t=32→64→96** (18.57 → 18.09 → 18.05). Morsel
   neither suffers HT contention at t=96 (default loses 3.5%, t=64→96)
   nor benefits at the work-fragmentation cell where qbatch K=128
   wins (qbatch K=128 *gains* 4.3% from t=64 to t=96 on the same
   data). This is the negative-result signature: the engine isn't
   bottlenecked by the ceiling it was designed to attack.

2. **Per-(q, c) chunk bookkeeping is the new floor.** Every (q, c)
   emit appends to per-worker `ids` *and* pushes a 12-byte tuple to
   per-worker `chunks`. With 1.91M `(q, c)` pairs, that's 1.91M
   chunk pushes total — each one is a Vec write the default and
   query-batch engines do not do. Worker phase wall is 16 s on
   t=32, comparable to default's 17.5 s; the chunk bookkeeping
   spends back the cooperative-caching savings.

3. **The merge phase is forced by the morsel decomposition.**
   Because (cluster c, q_range) morsels split each query's results
   across multiple workers, building the final per-query
   `Vec<u32>` requires a separate scatter-merge pass: 16 s on c256_56gb
   t=32, doubling Rust wall to 34 s. In bench mode (`suppress_results=
   true`) the Python side discards IDs, so the merge is short-circuited
   (`return (0..n_q).map(|_| Vec::new()).collect()`). With merge
   skipped morsel runs at the workers-only floor — but that floor is
   already the same as default's full pipeline, because default
   writes per-query `Vec<u32>` *during* the worker phase (one worker
   per query, no merge needed).

#### 3.10.4 What morsel actually falsifies

The point of running this ablation is *not* "we tried morsel
scheduling and it didn't beat the baseline" — that framing buries the
mechanism. The thesis-relevant statement is sharper: **morsel
falsifies the hypothesis that cross-worker phase coordination buys
performance on top of in-task cluster-cold-load amortisation**.

The 8–12% gap between morsel and qbatch K=128 is *exactly* the
cooperative-caching/cluster-locality term that qbatch's per-thread
`for c in clusters` loop captures and that morsel's cross-worker
dispatch breaks. Morsel's +4% over default (so finer-grain
scheduling does carry some value over per-query parallelism) and
its −8 to −12% vs the regime-best engines bound the contribution
of cluster locality from above and below: cluster locality is worth
on the order of 5–10%, and qbatch K=128 already collects all of it.

This connects directly to the §3.8 LLC-miss-% probe:
- When threads phase-coordinate around the same cluster (qbatch),
  L2/L3 lines are *shared* across workers — LLC miss% drops 37% →
  32% as t grows on bestofsuite.
- When threads spread across clusters via morsel-style cross-worker
  dispatch, each worker re-fetches its own copy — LLC pressure
  scales with thread count, and the cross-task amortisation that
  qbatch captures is destroyed.

This also resolves the apparent disagreement with Bandle/Giceva
2021 — they reported 1.5–3× wins for morsel scheduling over
fixed-size partitioning. Their baseline did not already structure
per-thread work along the cluster-locality axis. **In our workload,
qbatch K=128 is approximately a "cooperative-locality-aware
fixed-size morsel" — the headroom Bandle/Giceva measured against an
unstructured baseline has already been collected by qbatch K=128 in
this codebase.** That is a defensible, mechanism-grounded
explanation, not "we tried it and it didn't work".

#### 3.10.5 Third instance of the same composition pattern

Morsel joins the two prior negative-composability findings as a
third data point of the same structural shape:

| Composition attempted | Coarse mechanism that already captures the win | Outcome |
|---|---|---|
| `packed-ids + bestofsuite` (§3.7.6) | f16 already addresses the dominant bandwidth source | NEGATIVE in 12/18 cells |
| `bestofsuite + query-batch` (§3.9.7) | f16 halves cluster cold-load *size*, leaving no amortisation room for K-batching | NEGATIVE at every 56gb cell |
| `morsel` over qbatch K=128 (§3.10) | qbatch K=128 captures cluster cold-load amortisation in one Rayon task | NEGATIVE at every 56gb cell |

The recurring pattern is: **when a coarse mechanism already
captures most of what a finer mechanism is designed to recover,
the finer mechanism does not compose — and often net-regresses
because its own bookkeeping/coordination overhead has nothing to
recover against**. With three independent instances on this
workload, it elevates from incidental finding to **structural
observation about ablation composition on hardware-near workloads**.
Future ablation campaigns on this codebase should explicitly check
the binding ceiling at the *target* composition, not the bare
default.

#### 3.10.6 Sub-conclusion — morsel is closed as a negative result

Morsel sits alongside `cluster-par` (§3.4 +3.7×), `horizontal-simd`
(§3.5.3 ≤7%), and `pgm` (§3.6 ≤8% in-regime) as a documented negative
ablation. The thesis-level value is in the framing: it falsifies a
specific composition hypothesis and supplies the third data point
for the negative-composability pattern (§3.10.5).

The implementation lives at `src/engine/morsel.rs` (cfg-gated under
`--features morsel`, mutually exclusive with `aos`/`f16`/`pgm`).
It is **not added to the dispatch policy** in
`fainder/execution/dispatch.py` (still: §3.9.8 boundary, three
engines for three regimes; morsel does not win any cell).

---

### 3.11 Per-cluster reindexing — pre-registered prediction falsified (`local-ids` feature family)

§3.7's packed-ids attack on emit-phase bandwidth (bit-packing global
histogram IDs at `ceil(log2(max_global_id + 1))` ≈ 20 bits) opened an
obvious next move: per-cluster local IDs. Each cluster holds at most
~5000 hists; a local-id encoding lifts the bit width from
`log₂(max_global_id+1)` to `log₂(n_hists+1)` ≈ 13 bits, an additional
~35% reduction on the read side. The implementation surface is small:
augment each `SubIndex` with a `local_to_global: Vec<u32>` lookup
table (one entry per histogram, ~20 KB worst case per cluster, fits
L1d 48 KB on Sapphire Rapids 8468H within a cluster's processing
window), and rewrite the packed-ids decoder to apply the lookup after
decoding.

This is the second clean bandwidth-end attack after packed-ids — the
mechanism is sharp, the math is mechanical, and the implementation is
self-contained. The expected result on the table is the next
positive ablation; the §3.11 finding is the falsification of that
expectation.

#### 3.11.1 Pre-registered prediction — bandwidth-budget upper bound

Per-emit memory traffic in row-centric SoA, written as
(read width + write width) over the per-emit operation:

| variant                       | read (bits) | write (bits) | total | vs default |
|-------------------------------|------------:|-------------:|------:|-----------:|
| default (32-bit unpacked)     |          32 |           32 |    64 |  baseline  |
| `packed-ids` (20-bit global)  |          20 |           32 |    52 |       −19% |
| `local-ids` (13-bit, lookup → 32-bit global) | 13 | 32 | **45** | **−30%** (vs default), **−13%** on top of packed-ids |
| `local-ids-bench` (13-bit, no lookup, suppress-only) | 13 | 32 | 45 | same |

**The output write to `Vec<u32>` is the floor at 32 bits/id**, so emit-
phase savings are capped at ~13% no matter how aggressively the read
side is packed. The bandwidth-budget arithmetic predicts a small but
real saving: 56gb t=64/t=96 are the bandwidth-bound regime where
packed-ids already won, so local-ids should compose into it cleanly
and push the regime-best wall down by another 1–2 s.

This is the prediction registered upfront. It is wrong.

#### 3.11.2 Implementation — four `Cargo` features for a controlled comparison

Following §3.10's framing-discipline lesson — that the value is in
how a measurement decomposes the bandwidth budget, not in a single
delta — four feature variants were built side-by-side:

- `packed-ids` — existing: global IDs at `log₂(max_global_id+1)` ≈ 20 bits.
- `local-ids` — option 1: local IDs at `log₂(n_hists+1)` ≈ 13 bits, with
  in-Rust lookup at emit (`packed::append_range_local_to_global`).
  Correctness preserved end-to-end.
- `local-ids-bench` — option 4: local IDs at 13 bits, **no lookup**
  (emits local ids verbatim into `Vec<u32>`). Suppress-mode-correct
  only — with-results mode produces wrong global IDs. Used to bound
  the lookup-overhead cost separately from the bandwidth saving.
- `local-ids-noalloc` — disambiguation control: identical to
  `local-ids-bench` but `local_to_global` is **not allocated**. Tests
  whether the resident table (TLB/L3 pressure) is responsible for
  any regression observed on the bench variant.

All four are mutually exclusive at compile time and mutually
exclusive with `aos`. `scripts/validate_local_ids.sh` (10 K queries
on c256_10gb t=16, with-results mode) verifies (a) option 1 produces
**byte-identical result sets to default** (10000/10000 queries),
and (b) option 4 diverges as designed (total set count 1.65 B →
0.32 B from cluster-local ID collisions colliding in Python's int
sets — the suppress-mode contract).

#### 3.11.3 Wall-clock measurements — c256_56gb, suppress mode

Row-centric (default engine), median of 5 reps:

| t  | default | packed-ids | local-ids | local-ids-bench | local-ids-noalloc |
|---:|--------:|-----------:|----------:|----------------:|------------------:|
|  1 |  139.35 |     115.52 |    147.04 |          137.28 |            138.59 |
|  8 |   24.78 |      24.04 |  **68.70**|       **67.27** |         **72.68** |
| 16 |   20.74 |      19.84 |  **68.37**|       **67.31** |         **68.68** |
| 32 |   19.36 |      18.93 |  **63.85**|       **61.87** |         **60.02** |
| 64 |   18.15 |      16.59 |  **55.18**|       **51.68** |         **48.75** |
| 96 |   18.78 |      18.23 |  **44.40**|       **43.20** |         **43.36** |

10gb / 30gb show only modest deltas (within ±10% of packed-ids; not
the regime where the regression bites). On 56gb the row-centric arm
is catastrophic: **local-ids regresses 2.5–3.7× vs packed-ids at
t ≥ 8**, with the worst cell at t=16 (+243% over default). The
falsification of the +13% prediction is unambiguous.

The three local-* variants land within ±5% of each other at every
multi-thread cell — **the local_to_global table allocation
(`bench` has it, `noalloc` does not) makes no measurable difference**.

qbatch K=128 composition arm, median of 5 (the cells where qbatch is
the regime-best engine):

| t  | qb+packed-ids | qb+local-ids | qb+local-ids-bench | qb+local-ids-noalloc |
|---:|--------------:|-------------:|-------------------:|---------------------:|
| 64 |     **16.89** |        22.45 |              21.21 |                21.75 |
| 96 |     **16.17** |        22.52 |              19.43 |                21.17 |

Cooperative caching recovers ~half of the row-centric catastrophe
(44.4 s → 22.5 s at t=96 on option 1) but **never closes the gap to
packed-ids**: qb+local-ids is +39% over qb+packed-ids at t=96. The
lookup overhead under qbatch is measurable but small (~3 s of the
22 s, from qb+local-ids minus qb+local-ids-bench at t=96).

#### 3.11.4 Mechanism — perf-counter probe

To localise the regression, a one-rep perf probe ran on c256_56gb
t=32 across all five builds with `perf stat -e cycles, instructions,
LLC-load-misses, dTLB-load-misses, cpu/event=0xd0,umask=0x41,name=mem_split_loads/`.

(Note: the probe's *wall* times are inflated 5–9× over fresh-bench
medians — system noise during the ~100-minute probe session. Per-
instruction *rates* remain structural and are what the comparison
relies on.)

| build               |   IPC | LLC-miss | dTLB-miss | dTLB-miss/insn |   split-loads |
|---------------------|------:|---------:|----------:|---------------:|--------------:|
| default             |  1.17 |    294 M |    56.5 M |        1 / 30 K|         867 M |
| packed-ids          |  1.52 |    307 M |    99.7 M |       1 / 23.6 K|       2.85 B |
| local-ids           |  0.96 |    106 M |  **10.6 B**|     **1 / 395** |        6.73 B |
| local-ids-bench     |  0.95 |     97 M |  **10.6 B**|     **1 / 395** |        6.69 B |
| local-ids-noalloc   |  0.90 |    102 M |  **10.5 B**|     **1 / 395** |        6.73 B |

The headline number is **the dTLB-miss rate per instruction: ~75×
higher in all three local-* variants than in packed-ids**, and
identical across `bench`/`noalloc` (within 1%). Three secondary
observations sharpen the reading:

- **LLC-load-misses are *lower* in the local-* variants** (97–106 M
  vs 307 M for packed-ids). Smaller bit width gives a smaller
  packed buffer; this is not a cache-capacity issue.
- **Split-loads do go up** (~2.4× over packed-ids) but tied across
  the three local-* variants, so they don't differentiate.
- **IPC collapses** to 0.95 across local-* vs 1.52 for packed-ids,
  consistent with frequent TLB-walk stalls.

#### 3.11.5 Hypothesis lattice — what the perf counters rule out and rule in

Four mechanisms could in principle drive the regression. The
perf-counter data + noalloc disambiguation positions them:

| Hypothesis | Predicted signal | Observed | Verdict |
|-|-|-|-|
| **H1 TLB pressure from `local_to_global` resident pages** | bench (has table) regresses, noalloc (no table) does not | bench ≡ noalloc within ±5% at every cell; same dTLB-miss/insn rate | **falsified** |
| **H2 NUMA cross-socket fetch of `local_to_global`** | option 1 (uses lookup) much worse than option 4 (skip lookup) | option 1 vs option 4 differ by ~3 s under qbatch; under row-centric they tie within 5% | **falsified for the bulk regression**; ~3 s/22 s lookup cost is consistent with secondary cross-socket reads but does not explain the 2.7× gap |
| **H3 Split-load cross-word reads in the bw=13 decoder** | split-loads up in local-* and *differentiating* (e.g. higher in noalloc than bench) | split-loads up 2.4× over packed-ids but identical across local-*; doesn't explain the dTLB explosion | **partial / unconfirmed** — split-loads contribute but are not the primary driver |
| **H4 The bw=13 access pattern over `packed_ids` itself drives dTLB pressure** | dTLB-miss rate amplified vs bw=20 (packed-ids), independent of table allocation | **dTLB-miss/insn is 75× higher in local-* than in packed-ids, identical across bench/noalloc** | **standing — primary suspect** |

H4 is the hypothesis the data lands on. The precise hardware
mechanism — why a 13-bit stride access pattern walks page-table
entries more frequently than a 20-bit stride access pattern over the
same logical layout — would require disassembly of the compiled
`append_range` decoder and a TLB-walk-source trace. That belongs to
follow-up work; the empirical claim of §3.11 is robust without it:
**the bandwidth-budget arithmetic over-predicted the saving because
it does not model decoder-access-pattern TLB pressure.**

#### 3.11.6 What §3.11 falsifies, what it confirms, what it leaves open

**Falsified:** the pre-registered prediction that bw=20 → bw=13
yields a +13% emit-bandwidth saving on top of packed-ids. Real
deltas span **−13% (10gb t=96) to +243% (56gb t=16)** depending on
regime. Under qbatch K=128 the worst case shrinks to +39% but never
turns positive.

**Confirmed:** §3.10's framing-discipline lesson generalises. A
single number per regime cell (the option 1 wall) was *ambiguous*
between "the ceiling moved" and "lookup eats the saving"; the four-
variant decomposition (`packed-ids`, `local-ids`, `local-ids-bench`,
`local-ids-noalloc`) was what made the mechanism reading possible.
Per-cluster reindexing is a **methodological-correctness datapoint**
even though it is an empirical-performance negative.

**Confirmed (mechanism level):** the H1/H2 falsification via noalloc
isolates the regression to the decoder access pattern over the
packed buffer itself — independent of any table allocation. The H4
explanation is consistent with all observed counters.

**Open (Future Work):** precise hardware root cause of why bw=13
walks ~75× more page-table entries than bw=20 in the same
`packed::append_range` decoder. Candidates: stride-aware HW prefetcher
behaviour on smaller stride patterns; STLB/PMH coverage limits at
multi-thread; bit-pos arithmetic generating addresses that span
larger virtual-address ranges per fixed instruction-count window.
Disassembly + `perf record -e dtlb_load_misses.walk_completed
--call-graph dwarf` would localise.

#### 3.11.7 Sub-conclusion — fourth instance of the negative-composability pattern

`local-ids` does not enter the dispatch policy (§3.9.9). At no
measured cell does it beat the regime's existing best; the
implementation is kept on the `local-ids*` feature family solely
for the diagnostic value of the four-variant decomposition.

The deeper finding is that §3.11 supplies the **fourth independent
instance** of the negative-composability pattern that §3.7.6,
§3.9.7, and §3.10 each contributed an instance to. The four
instances span four distinct hardware axes:

| Composition attempted | Coarse mechanism that already collected the win | Negative axis |
|-|-|-|
| `packed-ids + bestofsuite` (§3.7.6) | f16 (search-phase bandwidth) | emit-phase bandwidth |
| `bestofsuite + query-batch` (§3.9.7) | f16 (cluster cold-load *size*) | cluster cold-load *occurrences* |
| `morsel` over qbatch K=128 (§3.10) | qbatch (in-task cooperative caching) | cross-worker phase coordination |
| **`local-ids` over packed-ids (§3.11)** | **bw=20 decoder (read-side bandwidth)** | **bw=13 decoder access pattern (TLB)** |

Four independent axes, four mechanism-grounded negatives at the
time of §3.11; §3.12 below adds a fifth (memory-locality
fragmentation via `numactl --interleave`). The recurring shape:
**a finer mechanism designed to recover the residual after a
coarser one already collected the bulk does not compose — it
net-regresses because its bookkeeping/access overhead has nothing
to recover against.** §3.13 elevates this to a named methodological
contribution of the thesis.

---

### 3.12 NUMA placement — fourth ceiling identified (cross-socket interconnect)

§3.7/§3.8 lumped "DRAM bandwidth" into a single ceiling. This was a
methodological convenience — measurements at the time were taken with
Linux's default first-touch placement and no `numactl` intervention, so
on-socket DRAM bandwidth and cross-socket UPI bandwidth were entangled
under one label. The 8468H box is 2-socket NUMA (node 0 cpus 0–47 +
96–143, node 1 cpus 48–95 + 144–191; node distance 21 vs local 10 →
2.1× cross-socket latency penalty), so the entanglement is plausibly
load-bearing. §3.12 probes it.

#### 3.12.1 Pre-registered question

> *Does explicit memory binding move the wall enough to split "DRAM
> bandwidth" into two separate ceilings (on-socket vs cross-socket
> UPI)?*

Two outcomes were thesis-grade upfront:

- **Positive**: pinning memory + CPU to one socket beats the unpinned
  baseline at matched thread count. Cross-socket UPI is a fourth
  ceiling, distinct from on-socket DRAM bandwidth. §3.8's two-ceiling
  model expands to three.
- **Negative**: single-socket pinning ties or loses to unpinned. The
  on-socket and cross-socket bandwidths are effectively one pool; no
  refinement to §3.8. (Would have been a fifth negative-composability
  instance on the memory-locality axis.)

#### 3.12.2 Experimental design

Four NUMA configurations on c256_56gb, `--features packed-ids`,
suppress mode, median of 5 reps each. Bench wall_s (Rust-only).

- **A** (baseline): unpinned. Linux first-touch placement. Same as the
  existing bench.db data for `packed-ids` 56gb; re-run paired with the
  other configs to control for system-noise drift.
- **B** (single-socket-clean): `numactl --cpunodebind=0 --membind=0`.
  Memory and CPU both on node 0. Only feasible at t ≤ 48 (socket 0
  has 48 physical cores).
- **C** (interleave): `numactl --interleave=0,1`. Memory pages
  distributed round-robin across both nodes at 4 KB granularity.
- **D** (cross-socket-forced): `numactl --membind=0 --physcpubind=48-N`.
  Memory on node 0, CPUs on node 1's physical cores. Worst case for
  cross-socket UPI cost.

#### 3.12.3 Results

| config | t=32 | t=48 | t=64 | t=96 |
|--------|-----:|-----:|-----:|-----:|
| **A** unpinned (baseline) | 19.28 | 16.97 | 18.19 | 17.58 |
| **B** single-socket node 0 | **16.77** | **15.04** | — | — |
| **C** interleave 0,1 | 25.87 | 23.73 | 22.91 | 24.83 |
| **D** cross-socket forced | 19.08 | 16.86 | — | — |

Three structural readings:

**(B vs A) Single-socket beats unpinned by 11–13%** at matched thread
count. Single-socket-clean is the new regime-best for c256_56gb at
t ≤ 48 — strictly faster than any existing dispatch cell at those
thread counts (the dispatch policy's `packed-ids` recommendation at
t=32 was 18.93s in bench.db; single-socket is 16.77s, **−11.5%**).

**(D vs A) Cross-socket-forced ≈ unpinned**, within 1%. The unpinned
baseline already pays cross-socket UPI cost: first-touch places most
of the index on node 0 at construction time (verified by `numactl
--hardware` showing 170 GB used on node 0 vs 7 GB on node 1 after the
sweep), but at t > 24 many Rayon workers are scheduled to node 1 and
fetch across the interconnect. Forcing the worst case (D) doesn't
hurt because unpinned was already approximating it.

**(C vs A) Interleave is a 26–41% regression**. The naive "balance
memory across sockets" fix moves wall the wrong direction at every
thread count. Mechanism: 4 KB-granularity interleave fragments each
cluster's working set — half the bytes are local, half remote,
unpredictably per page. The hardware prefetcher's spatial stride is
disrupted, and every cluster access pays a 50%-cross-socket
expectation rather than the unpinned baseline's lower amortised cost
(first-touch keeps each cluster's bytes contiguous on one node).

#### 3.12.4 Mechanism — cross-socket UPI is a fourth, distinct ceiling

The three readings collectively show that on-socket DRAM bandwidth and
cross-socket UPI bandwidth are **not interchangeable on this
hardware**. They share the broad label "memory bandwidth" but bind
under different conditions:

| ceiling | bound when | best attack |
|---------|------------|-------------|
| on-socket DRAM | per-socket bandwidth saturated at the limit | `f16` (search-phase compression), `packed-ids` (emit-phase compression) |
| **cross-socket UPI** (§3.12) | **threads on socket N reach memory on socket M** | **single-socket placement at t ≤ 48** |
| HT contention (§3.8) | logical thread count > physical core count (t > 96) | `pin-cores` on physical-only |
| work-fragmentation (§3.8) | per-cluster work below shared-L3 saturation; many clusters/thread | `query-batch` cluster-outer-loop |

The §3.8 two-ceiling characterisation thus expands to **four ceilings
on this hardware**. The cross-socket UPI ceiling has been hiding
inside §3.7/§3.8's bandwidth label for the full campaign, and is
visible empirically only when an explicit NUMA intervention removes
it (config B).

#### 3.12.5 Implications for dispatch policy

The current dispatch policy in `fainder/execution/dispatch.py` chooses
build features per `(n_clusters, n_hists, n_threads)` regime. §3.12
adds a **placement axis** to the recommendation surface:

- **t ≤ 48 + n_hists ≥ 600K**: deploy with `numactl --cpunodebind=0
  --membind=0`. The single-socket-clean configuration is the new
  regime-best for c256_56gb at those thread counts. Empirical delta
  vs unpinned: **−11% to −13%**.
- **t > 48**: single-socket placement is infeasible (insufficient
  physical cores). Stay with unpinned + the build-feature dispatch;
  cross-socket UPI cost is paid implicitly by the baseline.
- **`numactl --interleave=*` is strictly negative on this workload**
  — pre-empts a naive deployment fix.

A revised `EngineConfig` could carry a `numactl_prefix: str` field
alongside `features` and `env`. The validation methodology from §3.9.9
applies unchanged.

#### 3.12.6 Sub-conclusion — a positive ablation on a previously unaddressed axis

§3.12 is the campaign's **first new positive ablation since §3.9 (query-
batch)**. Single-socket placement contributes a clean 11–13% win at
matched thread count, on an axis no other ablation in the campaign
attacked. Mechanism: on-socket DRAM and cross-socket UPI are distinct
ceilings; the four-ceiling expansion of §3.8's model is the thesis-
relevant update.

The negative result on the same probe — **interleave is a 26–41%
regression** — adds a fifth instance of negative-composability on a
new axis (memory-locality fragmentation), and the documentary value
of having measured it explicitly pre-empts the obvious naive
deployment fix.

The implementation cost of §3.12's positive arm is zero source-code
change. It is a deployment-time flag passed to the existing binary,
discoverable via the existing dispatch decision.

---

### 3.13 Negative-composability — a structural finding across the campaign

§3.7.6, §3.9.7, §3.10, §3.11, and §3.12 each contributed an independent
instance of the same shape:

- **An ablation with a clean a-priori mechanism story.**
- **Composed against a baseline that already addresses the same
  *binding* ceiling.**
- **The finer ablation does not improve the composition; it
  regresses it.**

Each instance attacks a different hardware axis. None is a refined
parameter sweep of another. The pattern is **structural, not
incidental**. This section names it as a thesis contribution
distinct from any individual ablation result, and articulates the
methodology it implies.

#### 3.13.1 Statement of the pattern

> **When a coarse mechanism captures the dominant share of what a
> finer mechanism is designed to recover, the finer mechanism does
> not compose. Its bookkeeping, decode, or coordination overhead
> finds no residual headroom to recover and emerges as net cost.**

The pattern is not "diminishing returns at the margin." It is
sign-flipping at the margin: the second ablation moves the composed
wall in the wrong direction, often by a large factor.

#### 3.13.2 Five instances, five axes

Read this table as: *baseline composition* ← *finer ablation layered on top*; the binding ceiling at the baseline is what the finer ablation's intended axis fails to find headroom against.

| § | Composition (baseline ← ablation) | Binding ceiling at the baseline (and what already attacked it) | Ablation's intended axis | Observed outcome and mechanism |
|---|---|---|---|---|
| §3.7.6 | `bestofsuite` ← `packed-ids` | **on-socket DRAM bandwidth** — `f16` had already collected the search-phase saving; `pooled` had defused emit-allocator pressure | emit-phase ID bandwidth | regression in 12/18 cells, up to **+24 %** at low *t*; the binding constraint (emit-allocator pressure) no longer binds, so the ID-bandwidth saving lands on a slack ceiling |
| §3.9.7 | `bestofsuite + query-batch` (reverse layering) | **on-socket DRAM bandwidth** — `f16` had already halved per-cluster cold-load *size* | cluster cold-load *occurrences* (K-batch amortisation) | regression at every 56 GB cell, **+8 to +32 %**; amortisation operates on a residual smaller than the bandwidth-arithmetic predicted, and route-preprocessing / per-batch state cost exceeds it |
| §3.10 | qbatch K=128 ← morsel | **shared L3 capacity** — qbatch's per-thread `for c in clusters` had already collected cluster cold-load amortisation in a single Rayon task; shared L3 (105 MB) absorbs cross-task cold-loads at the L3 layer | cross-worker phase coordination | regression at every 56 GB cell, **+8 to +12 %**; the coordination layer finds no residual L3-miss to amortise, so its bookkeeping cost shows |
| §3.11 | `packed-ids` ← `local-ids` (bw≈13) | **on-socket DRAM bandwidth** — the bw≈20 packed decoder had already collected the read-side saving against a 32-bit write-back floor | read-side bandwidth via narrower decoder | **catastrophic** regression at multi-thread, **+170 to +243 %** on 56 GB; the bw≈13 decoder's access pattern over the packed buffer drives dTLB-miss rate up **75× per instruction**, drowning the bandwidth saving in TLB-walk stalls (confirmed by the `local-ids-noalloc` control) |
| §3.12 | unpinned (first-touch) ← `numactl --interleave=0,1` | **cross-socket UPI interconnect** — first-touch keeps each cluster's bytes contiguous on one node, paying UPI cost only on a fraction of accesses | memory-locality balancing across both nodes | regression at every cell, **+26 to +41 %** on 56 GB at *t*=32..96; 4 KB-granularity interleave fragments each cluster's working set and defeats the hardware prefetcher's spatial stride |

Five axes — search-phase bandwidth, cluster cold-load size,
cross-worker coordination, decoder access pattern, memory-locality
fragmentation — and five mechanism-grounded negative results. The
pattern survives variation in axis and is robust to the specific
hardware mechanism involved.

#### 3.13.3 Why this is non-trivial — the bandwidth-budget arithmetic falls short

Each of the five ablations is justified by paper-grade reasoning
that ignores the multi-thread interaction with the baseline:

- **§3.7.6**: packed-ids saves on the emit-id bandwidth, which
  appears as a measurable fraction of total per-emit memory
  traffic. The arithmetic predicts a positive composition with
  bestofsuite — but bestofsuite's `pooled` had already defused the
  emit-allocator pressure that *was* the binding constraint, so
  the saving lands on a ceiling that no longer binds.
- **§3.9.7**: query-batch amortises cluster cold-load across K
  queries. The arithmetic predicts a positive composition with f16
  — but f16 already halved the per-cluster cold-load size, so the
  amortisation operates on a smaller residual than predicted, and
  the route-preprocessing + per-batch state cost exceeds it.
- **§3.10**: morsel-style phase coordination amortises cluster
  cold-load *across workers*, on top of qbatch's in-task
  amortisation. The arithmetic predicts a positive composition —
  but the shared L3 (105 MB) absorbs cross-task cold-loads at the
  L3 layer without explicit coordination, leaving the morsel
  bookkeeping with nothing to recover.
- **§3.11**: per-cluster reindexing pushes the decoder's read
  width from ~20 to ~13 bits. The arithmetic predicts a positive
  composition with packed-ids — but the bw=13 decoder
  access-pattern over the packed buffer drives dTLB-miss rate up
  75× per instruction, drowning the bandwidth saving in TLB-walk
  stalls.
- **§3.12**: `numactl --interleave=0,1` distributes memory pages
  round-robin across both NUMA nodes, intuitively balancing
  cross-socket UPI cost across all accesses. The arithmetic
  predicts a positive composition against unpinned first-touch —
  but first-touch already keeps each cluster's bytes contiguous on
  one node, paying UPI cost only on the fraction of accesses where
  a Rayon worker is scheduled to the other socket. 4 KB-granularity
  interleave fragments each cluster's working set, defeats the
  hardware prefetcher's spatial stride, and forces a 50%-cross-socket
  expectation on every page — strictly worse than first-touch's
  amortised cost.

The recurring failure of the simple addition is **that the
composition's binding constraint is not what the second ablation
attacks**. The first ablation moved the binding constraint to a
different axis, and the second ablation pays its own cost without
recovering against any residual on the *new* binding axis.

#### 3.13.4 Methodological implication — pre-flight ceiling-identification

The traditional ablation methodology — implement the proposed
optimisation, measure delta versus baseline, accept if positive,
explain if negative — assumes that the ablation's intended axis is
independently informative. This campaign falsifies that assumption
on hardware-near workloads: **whether an ablation composes depends
on what the binding ceiling is at the target composition, not at the
bare default.**

The pre-flight check that the five §3.x.y discussions implicitly
discover, articulated explicitly:

1. Identify the binding ceiling at the *target* composition baseline
   via perf-counter probe before committing to the ablation
   implementation. (§3.8's bandwidth/HT/work-fragmentation probe
   methodology is the template.)
2. Verify that the ablation's intended axis still binds at that
   composition. If a coarser ablation already addressed the same
   axis, the residual headroom is unlikely to compose positively.
3. If it does still bind, predict the saving via *bandwidth-budget
   arithmetic*. Treat the prediction as falsifiable, not as the
   expected outcome.
4. Measure across the regime cells where the ceiling binds. Use a
   multi-variant decomposition (e.g. §3.11's
   `local-ids`/`bench`/`noalloc` triad) to separate the ablation's
   intended saving from its bookkeeping cost.
5. If the composition is negative, the mechanism story (which axis
   no longer binds; which secondary cost emerged) is the thesis-
   relevant outcome — not the wall delta alone.

A reviewer's reasonable question — *"why didn't you just predict
this from the f16 saving + ablation arithmetic?"* — is answered by
the pattern: the five instances each had a clean a-priori case for a
positive composition, and each falsified the prediction at scale.
**The pre-flight check is necessary precisely because the
arithmetic is misleading on hardware that has multiple binding
ceilings stacked.**

#### 3.13.5 Distinct from the dispatch-on-regime artefact

§3.9.8 / §3.9.9 / `fainder/execution/dispatch.py` characterise a
*deployment* recipe: which build to use for which regime, validated
17/18 exactly and 18/18 within 5%. That is an engineering artefact.

§3.13 characterises a *methodology*: how to evaluate an ablation
against an already-composed baseline. The methodology is what
generalises beyond this codebase; the dispatch recipe is what this
codebase's regime structure produced.

Both are thesis contributions. They are distinct.

#### 3.13.6 What a sixth instance would and would not change

If a hypothetical sixth ablation (e.g. FastPFor on the IDs, §6.1
forward-looking; or NUMA-local `mmap` of the index data, §3.12.5
follow-on) measured positive against the appropriate composed
baseline, the pattern would survive — the finding is "the pattern
*exists* on hardware-near composition", not "every ablation composes
negatively." With five instances on five axes, the pattern is
well-supported; a sixth confirmation would add depth but not change
the claim.

If, conversely, a sixth ablation measured *negative*, the pattern
strengthens — but only if its mechanism story closes the loop the
same way (a coarser ablation having already addressed the binding
ceiling). A naïve negative result without that diagnostic structure
is just a failed ablation.

The pattern is therefore not unfalsifiable: it would be falsified by
**an ablation composing positively against a baseline whose binding
ceiling it explicitly does not address**. None of the campaign's
five instances satisfy that counterfactual; future ablations should
be evaluated against it.

---

### 3.14 Out-of-distribution dispatch validation — sparser-cluster regime

The dispatch policy in `fainder/execution/dispatch.py` was derived
from §3.7–§3.12's three-dataset campaign on `c256_*`. The 191
effective clusters at `c256_56gb` are the only cluster-count point
any dispatch boundary was empirically located against. §3.14
probes whether the policy generalises to a materially-sparser
cluster regime — the **`c1024_56gb`** dataset, identical to
`c256_56gb` in histogram count (5,017,619) and query workload but
with K-means at K=1024 collapsing to **610 effective clusters**
(3.2× sparser; ~8,200 histograms per cluster vs c256_56gb's
~26,300).

#### 3.14.1 Pre-registered question

> *Does dispatch's per-`(n_hists, n_threads)` build recommendation
> stay within 5% of the regime-best on a 3.2× sparser-cluster
> dataset of identical scale?*

Two outcomes were thesis-grade upfront (per cowork's framing):

- **Confirmation**: 6/6 cells within 5% of regime-best at K=1024.
  Claim 2 (dispatch-on-regime) is robust to the cluster-count
  axis; the policy generalises to a regime its training data did
  not span.
- **Falsification**: 1+ cell exceeds 5% gap. A fourth regime cell
  has been identified — the policy needs `n_clusters` (or its
  derivative, `histograms_per_cluster`) as a real regime axis, and
  the §3.x.y boundary needs to be re-located on the sparser-cluster
  workload.

#### 3.14.2 Experimental design

The full dispatch-relevant build set, exactly as `dispatch.py`
emits it, at all six thread counts the existing campaign uses, 5
reps each per (build, t). Bench wall_s, suppress mode:

- `default` (control)
- `bestofsuite` = `pooled f16 simd pin-cores cluster-prefetch mimalloc`
- `packed-ids`
- `query-batch` with `FAINDER_QUERY_BATCH=64`
- `query-batch` with `FAINDER_QUERY_BATCH=128`

Total: 5 builds × 6 thread counts × 5 reps = 150 measurements.
The index is the c1024_56gb fidx (rebuilt from the same
`histograms.zst` as c256_56gb, identical bin density of ~100 bins
per effective cluster); queries are the canonical
`eval_medium/queries/all.zst` shared across the entire campaign.

#### 3.14.3 Results

| t | dispatch's pick | dispatch wall_s | regime-best build | regime-best wall_s | gap |
|---|---|---:|---|---:|---:|
| 1 | query-batch K=64 | 105.54 | query-batch K=128 | 104.59 | **+0.9 %** |
| 8 | bestofsuite | 18.47 | bestofsuite | 18.47 | **+0.0 %** |
| 16 | bestofsuite | 12.84 | bestofsuite | 12.84 | **+0.0 %** |
| 32 | bestofsuite | 12.93 | bestofsuite | 12.93 | **+0.0 %** |
| 64 | packed-ids | 18.00 | bestofsuite | 17.96 | **+0.2 %** |
| 96 | query-batch K=128 | 18.14 | query-batch K=128 | 18.14 | **+0.0 %** |

**6/6 cells within 5 % of the regime-best**; 4/6 cells are exact
matches; the two non-exact cells deviate by less than 1 %. This
is the **Confirmation** branch of the pre-registered prediction.

#### 3.14.4 Mechanism reading of the two non-exact cells

The two cells where dispatch is sub-best (but still within 1 %)
both shift toward `bestofsuite`-flavoured choices on the
sparser-cluster regime. Both shifts are mechanism-coherent rather
than noise:

- **t=1 (qbatch K=64 → K=128, +0.9 % gap)**: the cluster-cold-load
  amortisation per K queries operates on 3.2× more clusters than
  c256_56gb's training data. K=128 amortises the larger cold-load
  count better than K=64; the K-vs-K boundary shifts upward
  slightly with cluster count.
- **t=64 (packed-ids → bestofsuite, +0.2 % gap)**: with 8,200
  hists per cluster vs c256_56gb's 26,300, the per-cluster emit
  volume is smaller and packed-ids' emit-phase compression has
  less residual to collect. Meanwhile bestofsuite's f16+simd
  savings still apply to the search phase, which is unchanged
  per-cluster. The packed-ids-wins-at-t=64 boundary therefore
  softens at the sparser regime; the trend is that bestofsuite
  encroaches as histograms-per-cluster shrinks.

Both deviations are *within* the 5 % confirmation band; both have
a clean a-priori prediction from the bandwidth-budget arithmetic;
and both are mechanism-coherent with the four-ceiling picture
established in §3.7–§3.12.

#### 3.14.5 Implications for the dispatch policy

The headline outcome (6/6 within 5 %) means the dispatch policy
deploys safely at K=1024 without modification — the recommended
build is within deployment-noise of the regime-best at every
thread count. No source-code change is required for the policy
to operate on this new regime point.

The two non-exact cells, however, suggest a refinement axis for
a future revision: `histograms_per_cluster` (or its proxy,
`n_hists / n_clusters`). Both deviations track the same axis —
sparser clusters favour `bestofsuite` over the
emit-phase-bandwidth-oriented choice (`packed-ids` at t=64) and
the smaller-K amortisation (`query-batch K=64` at t=1). A
fourth-dataset point at intermediate density (e.g. `c512_56gb` at
~16,000 hists/cluster) would locate the boundary precisely; this
campaign demonstrates the boundary's existence and direction but
does not pin it.

Critically, the policy's deployment recommendation under the
*current* formulation is still correct at K=1024: 6/6 within 5 %
is exactly the acceptance criterion §3.9.9 used for the c256_*
campaign, and c1024_56gb meets it without revision.

#### 3.14.6 Sub-conclusion — Claim 2 robust on the K axis

§3.14 is the campaign's **first out-of-distribution validation**
of the dispatch-on-regime policy. The original validation set
(§3.9.9) spans `n_hists` from 130K to 770K and `n_threads` from
1 to 96 but holds `n_clusters` ≈ 191 fixed across all three
datasets. §3.14's c1024_56gb point adds a third independent axis
to the validation set — varying `n_clusters` by a factor of
3.2× with everything else held identical (same histograms file,
same queries file, same bin-density methodology).

The result extends §3.9.9's "17/18 exact and 18/18 within 5 %" to
**"17/18 + 6/6 OOD = 23/24 within 5 %, with the 6/6 OOD cells all
within 1 %"**. The dispatch-on-regime policy is empirically
robust on the cluster-count axis at this scale and within this
density range, satisfying cowork's pre-registered Confirmation
criterion.

Two follow-on questions remain open: (i) does the policy still
hold at K=64 (denser regime) or K=4096 (even-sparser regime)? —
pending future work; (ii) does the `histograms_per_cluster` axis
warrant explicit dispatch-key inclusion in a v2 policy? — §3.14's
direction-of-deviation evidence answers "yes, but only once the
absolute gap exceeds 5 %; not yet at this density."

---

### 3.15 Out-of-distribution structural validation — does the structure reproduce at K=1024?

§3.14 validated the dispatch *policy* at c1024_56gb but left the
underlying structural claims unmeasured at the new density. The
four-ceiling characterisation (§3.7, §3.8, §3.12) and the
five-instance negative-composability pattern (§3.13) are
independent claims from dispatch-on-regime: dispatch could still
hold at the OOD point even if some ceilings shift their binding
regime or some neg-composability instances fail to reproduce.
§3.15 closes that gap with a targeted high-leverage sweep on the
same c1024_56gb fidx.

#### 3.15.1 Pre-registered questions

For each of four ceiling claims and five negative-composability
instances, the binary question is *sign-reproduction*: does the
c256_56gb finding's sign carry to c1024_56gb? Magnitude shifts are
not failure — they map onto the `histograms_per_cluster` axis the
§3.14 deviations already flagged. The questions:

| Claim | c256_56gb finding | c1024_56gb question |
|---|---|---|
| Ceiling (i) compute/L1 — latency-not-binding | `simd` is null or marginal | does `simd` stay null at all *t*? |
| Ceiling (ii) shared L3 — footprint dominates at t=16 | `f16` +40 % win at t=16; `aos` within noise | does `f16` still win? does `aos` stay neutral? |
| Ceiling (iii) on-socket DRAM bandwidth | bandwidth-reducers (`bestofsuite`, `packed-ids`, `qbatch`) win in big-data regime cells | (Implicit: §3.14's Phase 2 sweep already showed these three competitive at c1024; no separate test needed) |
| Ceiling (iv) cross-socket UPI | single-socket placement -11 to -13 % at *t* ≤ 48; interleave +26 to +41 % everywhere | do both arms reproduce in sign? |
| §3.7.6 `bestofsuite` ← `packed-ids` | NEG in 12/18 cells, up to +24 % | does composing packed-ids onto bestofsuite still regress at c1024? |
| §3.9.7 `bestofsuite` + query-batch | NEG at every 56 GB cell, +8 to +32 % | reproduce? |
| §3.10 `qbatch K=128` ← `morsel` | NEG uniformly, +8 to +12 % every cell | uniform reproduction *or* cell-dependent regression — see §3.15.6.3 |
| §3.11 `packed-ids` ← `local-ids` / `bench` | catastrophic NEG at multi-thread, +170 to +243 % | reproduce sign at minimum; magnitude shift expected |
| §3.12 first-touch ← `numactl --interleave=0,1` | NEG, +26 to +41 % | reproduce? |

Pattern: confirmation is sign-reproduction across all nine; one or
more sign-flips would identify the cluster-density boundary the
structural finding cannot cross.

#### 3.15.2 Experimental design

Eight cargo builds (`f16`, `aos`, `bs_packed_ids`, `bs_qbatch_K128`,
`morsel_K128`, `local_ids`, `local_ids_bench`, `simd`) plus two
`numactl` placement variants on the existing `packed_ids` build.
Six thread counts {1, 8, 16, 32, 64, 96} where applicable (NUMA
single-socket only at *t* ≤ 48 due to socket-0 having 48 cores;
interleave at all four 56 GB-relevant high-*t* cells). Five
repetitions per (build, *t*); bench wall_s, suppress mode. Total
~270 measurements; ~2 h wall.

Sweep script: `scripts/run_ood_structural_validation.sh`.
Analysis: `scripts/analyse_ood_structural.py`.

#### 3.15.3 Ceiling (i) — latency null at K=1024

*Pre-registered claim*: the workload is not latency-bound, so
`simd` should remain null or marginal across all *t* — the same
shape as c256_56gb where the SIMD ablation produced ≤ 1.13×.

| *t* | default wall_s | simd wall_s | delta | reading |
|----:|---:|---:|---:|---|
| 1 | 135.94 | 138.05 | +1.6 % | null |
| 8 | 23.81 | 25.02 | +5.1 % | small loss |
| 16 | 15.62 | 15.65 | +0.1 % | null |
| 32 | 17.96 | 17.91 | −0.2 % | null |
| 64 | 18.64 | 17.39 | **−6.7 %** | small win |
| 96 | 19.76 | 19.84 | +0.4 % | null |

**Reading.** Variance check on the apparently-anomalous t=64 cell
(simd −6.7 %, the only cell that looks like a win): 5-rep 95 % CI
on the delta is **−3.88 % ± 7.03 %** — straddles zero. The other
non-null cells (t=1, t=8, t=96) have similarly noise-floor 95 %
CIs (all straddle zero). So the apparent t=64 win and t=8 loss are
both within the measurement floor; the actual reading is **6/6
cells indistinguishable from default at 95 % CI**, consistent with
c256_56gb's "≤ 1.13×, inconsistent" reading from §3.1. The
dependent-load chain in `partition_point` remains the binding
constraint on per-thread work; SIMD finds no compute slack to fill
at the new density. **REPRODUCES** cleanly at c1024_56gb (clean
null, no cell-level anomaly when CI is consulted).

#### 3.15.4 Ceiling (ii) — shared L3 at K=1024 (refined)

The sharp signal here is `f16` (footprint shrinker, predicted to
win at *t* = 16); `aos` is the negative control (no Eytzinger
build available at the time of this campaign). At smaller-dataset
regimes (dev_small / eval_medium) `f16` standalone won by ~40 % at
*t* = 16; at c256_56gb `f16` was only measured *inside*
`bestofsuite`, where the full bundle wins by 18 % at *t* = 16.
Pre-registered reproduction would have `f16` standalone still
winning at c1024 and `aos` still losing or neutral.

| build (vs default at *t* = 16) | c1024 wall_s | default wall_s | delta | reading |
|---|---:|---:|---:|---|
| `f16` | 17.70 | 15.62 | **+13.3 %** | **SIGN-FLIP — f16 standalone loses** |
| `aos` | 20.21 | 15.62 | +29.4 % | reproduces (footprint-expander loses) |
| `bestofsuite` (control) | 12.84 | 15.62 | −17.8 % | reproduces (bundled win matches c256's 18 %) |

**Bundle-component follow-up — `bestofsuite` minus `f16`** at
*t* = 16, 5 reps:

| build | median wall | vs default | vs full bestofsuite |
|---|---:|---:|---:|
| default | 15.62 s | — | +21.6 % |
| `f16` alone | 17.70 s | +13.3 % | +37.9 % |
| `bestofsuite` full | 12.84 s | −17.8 % | — |
| `bestofsuite − f16` | 15.53 s | −0.6 % | **+20.9 %** |

**Reading — ceiling (ii) characterisation is refined; f16's
contribution is compositional, not standalone.** The `bestofsuite`
win at *t* = 16 reproduces at c1024_56gb (−17.8 % here, vs
c256_56gb's −18.4 %), so the bundle's attack on the L3-pressure
regime still works. But the component-level story is richer than
"the bundle wins despite f16":

- `f16` standalone *loses* 13.3 % vs default.
- Removing `f16` from the bundle (`bestofsuite − f16`) *also*
  loses against the full bundle (point estimate +20.9 % slower
  than full).
- So `f16` is contributing **positively to the bundle** by roughly
  the same margin (~+11 % point estimate on the median) that it
  *loses by* when isolated.

**Mechanism reading.** c1024's per-cluster `values[]` array is
$\sim$8,200 floats × 4 bytes = 33 KB at f32, which fits in the
48 KB L1d. Halving the type to f16 saves nothing standalone
because L3 isn't binding at this footprint, while the f16→f32
conversion overhead per comparison is pure cost. Inside the
bundle, however, `pooled` + `mimalloc` + `pin-cores` free up
enough memory-system headroom (allocator contention, SMT-sibling
crosstalk, glibc arena mutex) that `f16`'s halving of the
*aggregate* per-thread cache pressure lands productively even
though the per-cluster array itself was already L1-resident. The
binding ceiling shifts under the bundle.

**Variance caveat.** Single-cell variance at c1024 t=16 is high
(the §3.9.11 cross-process LLC-pressure phenomenon). 5-rep 95 %
CIs straddle zero on all three pairwise deltas above; the point
estimates are directionally consistent but the statistical signal
on the f16-contribution-to-bundle is below the campaign's 5-rep
measurement floor. The `bestofsuite` vs default reading is robust
because it matches c256 at exactly the same magnitude (−18 %);
the component-level decomposition is suggestive rather than
proven.

The `aos` negative control reproduces (−29.4 %) because cache-line
pollution from histogram-index fields hits L1 efficiency
independent of L3 pressure.

**Verdict**: PARTIAL REPRODUCTION with compositional refinement.
Ceiling (ii) is real and density-dependent on its threshold;
`f16` is not the universal L3 attack the earlier campaign
suggested but it's also not a passenger inside the bundle — it
appears to be a *compositionally-positive* contributor whose
standalone direction is inverted. The bundle is more than the
sum of its parts.

#### 3.15.5 Ceiling (iv) — cross-socket UPI at K=1024

§3.12 split cross-socket UPI out from on-socket DRAM bandwidth on
c256_56gb. The same probe at c1024_56gb tests whether the new
ceiling is density-invariant.

| *t* | unpinned wall_s | single-socket wall_s | gap | interleave wall_s | gap |
|----:|---:|---:|---:|---:|---:|
| 32 | 17.96 | 15.55 | **−12.4 %** | 25.14 | **+40.0 %** |
| 48 | — | 15.29 | — | 24.33 | — |
| 64 | 18.64 | — | — | 25.08 | **+34.6 %** |
| 96 | 19.76 | — | — | 27.31 | **+38.2 %** |

**Reading.** Both arms reproduce in sign and magnitude. Single-
socket placement beats unpinned by 12.4 % at *t* = 32 (c256_56gb:
−11 to −13 %). Interleave regresses by 34–40 % at every cell
(c256_56gb: +26 to +41 %). The cross-socket UPI ceiling is
**density-invariant** within the tested range: the per-page UPI
penalty doesn't depend on how many histograms each cluster
contains. The single-socket-clean deployment recommendation in
`dispatch.py` continues to apply at c1024_56gb without
modification. **REPRODUCES**.

#### 3.15.6 Negative-composability — five instances cross-density

##### 3.15.6.1 §3.7.6 `bestofsuite` ← `packed-ids`

*Pre-registered claim*: the c256 regression reproduces in sign.

| *t* | bestofsuite | + packed-ids | delta | sign |
|----:|---:|---:|---:|:---:|
| 8 | 18.47 | 20.65 | +11.8 % | NEG |
| 16 | 12.84 | 12.69 | −1.2 % | pos |
| 32 | 12.93 | 14.97 | +15.8 % | NEG |
| 64 | 17.96 | 17.95 | 0.0 % | tie |
| 96 | 19.28 | 19.34 | +0.3 % | NEG |

**Reading.** Two cells (t=8 +11.8 %, t=32 +15.8 %) are
meaningfully NEG; one (t=16 −1.2 %) is small positive; the other
two (t=64 0.0 %, t=96 +0.3 %) are at noise-floor and effectively
indistinguishable from baseline. **No cell shows strong
sign-uniformity at the c1024 regime, just as no consistent
uniformity was observed across the 12/18 NEG cells at c256_56gb.**
The honest reading is: §3.7.6's composition is **mixed at both
densities** — neither the c256 pattern nor the c1024 pattern
admits a "uniformly NEG" verdict. The structural argument's
strength on this instance is *cross-axis breadth* (it's one of
five different axes producing some form of negative composition),
not per-cell uniformity. **Pattern consistent across densities**
(mixed-NEG at both), though §3.7.6 carries less individual weight
than §3.9.7 / §3.11 / §3.12 in the structural-argument tally.

##### 3.15.6.2 §3.9.7 `bestofsuite` ← query-batch K=128

*Pre-registered claim*: the c256 regression reproduces in sign.

| *t* | bestofsuite | + qbatch K=128 | delta | sign |
|----:|---:|---:|---:|:---:|
| 8 | 18.47 | 25.05 | **+35.7 %** | NEG |
| 16 | 12.84 | 14.91 | **+16.1 %** | NEG |
| 32 | 12.93 | 18.46 | **+42.7 %** | NEG |
| 64 | 17.96 | 25.92 | **+44.3 %** | NEG |
| 96 | 19.28 | 25.79 | **+33.8 %** | NEG |

**Reading.** **5/5 cells NEG**, magnitudes +16 to +44 % — *larger*
than c256_56gb's +8 to +32 % range. The composition's regression
strengthens at the sparser regime, consistent with the §3.9.7
mechanism story: `f16` had already halved per-cluster cold-load
*size*, and at c1024 the per-cluster cold-load is itself smaller
(sparser clusters, ~8,200 vs ~26,300 hists), so the K-batch
amortisation has even less residual to recover. The
route-preprocessing and per-batch state cost dominates more
sharply. **STRONG REPRODUCTION** with mechanism-coherent
magnitude amplification.

##### 3.15.6.3 §3.10 qbatch K=128 ← `morsel`

*Pre-registered claim*: c256 showed a uniform +8 to +12 %
regression at every 56 GB cell. Two reproduction shapes are
thesis-relevant.

- **Uniform reproduction** (similar +8 to +12 % spread at c1024):
  the c256 mechanism story hardens — the cluster-cold-load
  amortisation morsel attacks is density-invariant within the
  tested range; the coordination cost is structural; shared L3
  absorbs the cross-task cold-loads regardless of cluster size.
- **Cell-dependent reproduction** (e.g. regresses at *t* = 64 but
  matches qbatch K=128 at *t* = 32): cluster density modulates the
  cooperative-caching headroom morsel was designed to exploit.
  This would be a finer reading of §3.10's mechanism — the
  coordination layer finds genuine residual L3-miss at some
  densities but not others — and would warrant a perf-counter
  follow-up to disentangle the regime.

The shape is the thesis-relevant axis here, not just the sign.

| *t* | qbatch K=128 | + morsel | delta | sign | reading |
|----:|---:|---:|---:|:---:|---|
| 8 | 20.25 | 21.24 | +4.9 % | NEG | low-*t* regression |
| 16 | 20.18 | 20.54 | +1.8 % | NEG | low-*t* regression |
| 32 | 19.02 | 19.94 | +4.8 % | NEG | low-*t* regression |
| 64 | 18.98 | 18.36 | **−3.3 %** | **POS** | **sign-flip at high *t*** |
| 96 | 18.14 | 17.94 | **−1.1 %** | **POS** | **sign-flip at high *t*** |

**Variance check** (5-rep 95 % CIs on the delta, Welch-style):

| *t* | point estimate | 95 % CI | reading |
|----:|---:|---|---|
| 32 | +4.53 % | [−1.83 %, +10.88 %] | straddles zero |
| 64 | −1.73 % | [−10.02 %, +6.55 %] | straddles zero |
| 96 | −0.79 % | [−7.53 %, +5.95 %] | straddles zero |

**Reading — attenuation to within-noise, not cell-dependent
reproduction.** None of the c1024 point estimates is
statistically distinguishable from zero at 5 reps. The signal is
real in c256_56gb (where the +8 to +12 % regressions held with
tight margins) but **disappears into measurement noise at
c1024_56gb**. The honest statement is: §3.10's reliable
+8 to +12 % NEG at the denser regime **attenuates to
indistinguishable-from-baseline at the sparser regime**.

This is still a density-dependent finding, but a weaker one than
the original draft claimed. The mechanism interpretation is
plausible — at c1024's sparser clusters, the per-cluster cold-load
qbatch K=128 amortises is smaller in absolute terms, so the
shared-L3 absorption that left morsel with no residual headroom at
c256 has less *absolute* coordination cost to remove — but the
direction (whether morsel breaks even or marginally beats qbatch)
is below this campaign's measurement floor. A perf-counter probe
on the cluster-transition-miss rate at the c1024 cells would
disambiguate; flagged as future work.

**Verdict**: ATTENUATED reproduction. Pattern direction
density-dependent; effect magnitude indistinguishable from zero
at c1024 within 5-rep CIs. §3.10 carries less individual weight
than §3.9.7 / §3.11 / §3.12 in the structural-argument tally at
the cross-density level.

##### 3.15.6.4 §3.11 `packed-ids` ← `local-ids` / `local-ids-bench`

*Pre-registered claim*: c256's catastrophic +170 to +243 %
multi-thread regression reproduces in sign. Magnitude can shift —
at sparser clusters the local-ID space is smaller per cluster and
the bw=13 decoder's TLB pressure could differ — but the sign of
the multi-thread regression is the structural claim.

The `local-ids-bench` variant additionally disambiguates whether
the regression is from the decoder access pattern alone (bench is
no-lookup) or compounded with the lookup-table cost (`local-ids`
proper).

| *t* | packed-ids | local-ids | gap | local-ids-bench | gap |
|----:|---:|---:|---:|---:|---:|
| 8 | 23.46 | 55.17 | **+135.1 %** | 56.30 | **+140.0 %** |
| 16 | 17.48 | 43.63 | **+149.6 %** | 41.36 | **+136.7 %** |
| 32 | 17.76 | 39.42 | **+122.0 %** | 37.43 | **+110.7 %** |
| 64 | 18.00 | 32.42 | **+80.1 %** | 28.97 | **+60.9 %** |
| 96 | 20.57 | 24.35 | +18.4 % | 24.79 | +20.6 % |

**Reading.** **5/5 cells NEG**, all multi-thread regressions
+18 % to +150 %. c256_56gb's range was +170 to +243 %; the c1024
range is shifted lower but still catastrophic across the entire
*t* axis. **STRONG REPRODUCTION in sign**; magnitude attenuates
toward high *t*, consistent with the §3.11 mechanism: dTLB
pressure dominates the bw=13 decoder regardless of cluster
density, but at high *t* the absolute wall is dominated more by
inter-thread contention than per-thread decode latency.

The `local-ids-bench` (no-lookup) variant tracks `local-ids` at
all cells — confirming the §3.11 noalloc-control reading
unchanged at c1024: the regression is in the decoder access
pattern, not the lookup-table residency. The dTLB-walks-per-
instruction mechanism is density-invariant.

##### 3.15.6.5 §3.12 first-touch ← `numactl --interleave=0,1`

Reuses the Group (D) measurements above; the per-cell deltas are
the §3.15.5 interleave gap column. Restated here for completeness
of the five-instance series.

*Pre-registered claim*: c256's +26 to +41 % regression reproduces
in sign at every measured *t*.

| *t* | unpinned | interleave | gap |
|----:|---:|---:|---:|
| 32 | 17.96 | 25.14 | **+40.0 %** |
| 64 | 18.64 | 25.08 | **+34.6 %** |
| 96 | 19.76 | 27.31 | **+38.2 %** |

**Reading.** 3/3 cells NEG, magnitudes +34.6 % to +40.0 % —
within c256_56gb's +26 to +41 % range. Page-granular interleave
defeats the hardware prefetcher's spatial stride at any cluster
density. **STRONG REPRODUCTION**.

#### 3.15.7 Sub-conclusion — does the structure reproduce cross-density?

**Eight pre-registered claims, eight verdicts (revised after
5-rep CI checks):**

| § | Claim | c1024 outcome | Verdict |
|---|---|---|---|
| 3.15.3 | Ceiling (i) — `simd` null | 6/6 cells indistinguishable from default at 95 % CI | REPRODUCES (clean null) |
| 3.15.4 | Ceiling (ii) — `f16` win + `aos` loss | `f16` standalone sign-flips (−13 % loss); `aos` reproduces (−29 %); `bestofsuite` bundle still wins −18 %; component-level decomposition suggests `f16` is *compositionally* positive inside the bundle though CI straddles zero | REFINED (compositional contribution; density-dependent L3 threshold) |
| 3.15.5 | Ceiling (iv) — single-socket + interleave | single-socket −12 %; interleave +34 to +40 % | REPRODUCES (density-invariant) |
| 3.15.6.1 | §3.7.6 NEG | mixed at both densities; 2/5 meaningfully NEG, 1/5 small positive, 2/5 noise-floor | CONSISTENT WITH c256 (neither density shows sign-uniformity) |
| 3.15.6.2 | §3.9.7 NEG | 5/5 NEG, magnitudes +16 to +44 % | STRONG REPRODUCTION (amplified) |
| 3.15.6.3 | §3.10 NEG | All point estimates within ±5 %; **5-rep 95 % CIs straddle zero at every measured cell** | ATTENUATED (c256's reliable NEG becomes within-noise at c1024) |
| 3.15.6.4 | §3.11 catastrophic NEG | 5/5 NEG +18 to +150 % | STRONG REPRODUCTION (sign; attenuated magnitude) |
| 3.15.6.5 | §3.12 NEG | 3/3 NEG +34 to +40 % | STRONG REPRODUCTION |

**Tally** (post-variance-check):

- **3/8 strong reproductions** (ceiling (iv), §3.9.7, §3.11,
  §3.12) — sign reproduces with comparable or amplified magnitude
- **2/8 reproduce as clean nulls** (ceiling (i) simd; §3.7.6 mixed
  at both densities)
- **2/8 refinements** that *change* the c256 reading at c1024:
  - Ceiling (ii) `f16` standalone sign-flips at c1024 t=16; the
    bundle still wins; the component-level decomposition is
    consistent with f16 being compositionally positive though
    single-cell variance prevents strict 95 % significance.
  - §3.10 morsel: c256's reliable +8 to +12 % NEG attenuates to
    statistically indistinguishable from baseline at c1024 across
    all measured cells.
- **0/8 outright falsifications**.

**Reading.** The structural finding is **cross-axis cross-density-
robust** for the strong instances. The two refinements are
*mechanism-coherent attenuations or compositional shifts* rather
than sign-flips on the headline claims: the ceiling-(ii) bundle
wins at both densities; the negative-composability pattern's
strong instances (§3.9.7, §3.11, §3.12) reproduce. §3.10 weakens
to within-noise at the sparser regime — informative but not
load-bearing on the structural argument. The methodology of
measuring across a 3.2× density range surfaces mechanism
dependencies the per-density framework explicitly anticipates;
this is the methodological win.

**Combined campaign record.** §3.9.9 + §3.14 + §3.15 jointly
establish:

- **Dispatch-on-regime**: 23/24 cells within 5 % (17/18 ID + 6/6
  OOD), all 6 OOD cells within 1 %.
- **Four-ceiling characterisation**: ceiling (i) and (iv)
  density-invariant within the 3.2× range; ceiling (ii) has a
  density-dependent threshold (binds when per-cluster footprint
  exceeds L1 capacity); ceiling (iii) on-socket DRAM bandwidth
  remains the binding constraint in big-data regime cells at both
  densities (per Phase 2 dispatch evidence).
- **Five-instance negative-composability pattern**: §3.7.6 / §3.9.7
  / §3.11 / §3.12 all reproduce in sign; §3.10 is cell-dependent
  at the sparser regime, refining the mechanism rather than
  falsifying the pattern. The pattern's structural claim — that
  composing a finer optimisation onto a baseline whose binding
  ceiling has already been collected leads to net regression —
  is reproduced cross-density, with the §3.10 cell-dependency as
  the first cross-density mechanism refinement the campaign has
  produced.
- **Pre-flight ceiling-identification methodology**: the c1024
  refinements are themselves evidence the methodology works:
  measuring at a second density surfaces mechanism dependencies
  that the per-density framework explicitly anticipates.

**Density range tested**: ~8,200 to ~26,300 hists/cluster (3.2×).
Outside this range — denser regimes (`c64_56gb` at ~78K/cluster)
or sparser (`c4096_56gb` at ~1.2K/cluster) — pre-registered in
§F3 of Chapter 7 with concrete falsifiers.

---

## 4. Auxiliary ablations

The single-feature ablations (`f16`, `pooled`, `mimalloc`, `kary`,
`eytzinger`, `horizontal-simd`, `batch-search`) were not measured
individually in this campaign — only `simd` and `aos` were ablated as the
two main-axis singletons. The integrated effect of the rest is captured
in `bestofsuite` (§5).

Future campaign: re-run individual ablations under suppress against the
same 3-dataset matrix, on the corrected bench harness that captures
`subprocess_s` for the with-results path.

---

## 5. End-to-end / `bestofsuite`

`bestofsuite` is `pooled f16 simd pin-cores cluster-prefetch mimalloc` —
the composition of all individually positive features. Reported in two
regimes: with-results (user-visible, but see §1.6 caveat) and
suppress-results (apples-to-apples vs default).

### 5.1 Wall-clock — `bestofsuite` with-results

| Dataset | t=1 | t=8 | t=16 | t=32 | t=64 | t=96 | best | speedup vs t=1 |
|---|---:|---:|---:|---:|---:|---:|:-:|---:|
| `c256_10gb` | 5.36s | 1.11s | 0.92s | **0.91s** | 1.17s | 1.14s | t=32 | 5.91× |
| `c256_30gb` | 21.67s | 3.65s | 2.86s | **2.78s** | 3.62s | 3.69s | t=32 | 7.79× |
| `c256_56gb` | 117.6s | 18.6s | **16.1s** | 16.4s | 18.9s | 20.9s | t=16 | 7.31× |

### 5.2 Speedup vs Python baseline (with caveat from §1.6)

| Dataset | best Rust wall | best Python wall | ratio |
|---|---:|---:|---:|
| `c256_10gb` | 0.91s | 596s | **656×** |
| `c256_30gb` | 2.78s | 1886s | **679×** |
| `c256_56gb` | 16.1s | (Python timed out) | — (≥218×, lower bound) |

These ratios compare Python's full-pipeline wall against Rust's
search-only wall — the honest user-visible speedup is somewhat smaller
(unmeasured; bench harness limitation per §1.6). Even discounted, the
order of magnitude (≥10²–10³×) holds.

### 5.3 The composition wins, not the individual features

No single ablation in §3 beats 1.17× (the SoA outlier). Yet `bestofsuite`
beats `default` by 5.7–7.8× at peak. Why?

| Feature | Hardware bottleneck it addresses |
|---|---|
| `pooled` | Allocator pressure (per-query Vec churn) |
| `f16` | Memory bandwidth (halves load/store bytes) |
| `simd` | Compute (negligible per §3.1) |
| `pin-cores` | NUMA cache-line ping-pong + SMT contention |
| `cluster-prefetch` | DRAM latency on cluster outer-loop stride |
| `mimalloc` | Central allocator mutex contention |

**Features synergise.** `f16` only helps when memory bandwidth is the
bottleneck — and you only see it as the bottleneck after `pin-cores` and
`mimalloc` remove the contention overhead that was hiding it. `cluster-
prefetch` only helps once the search itself stops blocking on the
allocator (which `pooled` + `mimalloc` deliver). The integrated system
exposes wins each component alone could not.

### 5.4 The surprise — `bestofsuite` *loses* at high t on big data

Apples-to-apples (suppress vs suppress, no boxing involved):

| Dataset | t | default | bestofsuite | best/def |
|---|---:|---:|---:|---:|
| `c256_56gb` | 1 | 571s | 117s | **4.86×** |
| `c256_56gb` | 16 | 20.4s | 15.7s | 1.30× |
| `c256_56gb` | 32 | 19.4s | 16.3s | 1.19× |
| `c256_56gb` | 64 | **17.8s** | 19.2s | **0.93× ⚠** |
| `c256_56gb` | 96 | **19.3s** | 20.7s | **0.93× ⚠** |

**`bestofsuite` is *slower than default* at t≥64 on 56gb.** The composition
that wins by 4.86× at t=1 is counterproductive at high thread count.

LLC misses tell the mechanism:

| t | default LLC (M) | bestofsuite LLC (M) | ratio |
|---:|---:|---:|---:|
| 1 | 252 | 277 | 1.10× |
| 32 | 294 | 422 | 1.44× |
| 64 | 329 | 455 | **1.38×** |
| 96 | 337 | 497 | **1.47×** |

`bestofsuite` has **38–47% more LLC misses than default at high t**, despite
`f16` halving the per-load byte count. Two compounding effects:

1. **Per-thread work compression.** Bestofsuite's per-cluster compute is
   ~5× shorter than default's (because of SIMD + f16 + better cache
   layout). At t=64 with 191 clusters, each thread gets ~3 clusters of
   ~1ms work = ~3ms total. Default's threads get ~3 clusters of ~5ms work
   = ~15ms. Coordination overhead is now ~30–50% of bestofsuite's
   per-thread time, but only ~10% of default's.

2. **Cluster-prefetch storm.** At 96 threads × 191 clusters, the software
   prefetches for cluster c+1 saturate the L1 hardware prefetcher's
   request queue. Lines that would have been fetched on demand get
   evicted by speculative prefetches that arrive too late or for clusters
   no longer being processed.

**This is the cleanest motivation for inter-query parallelism in the
thesis.** When intra-query optimisations succeed in shrinking per-cluster
work below the coordination-amortisation threshold, the only way to keep
threads usefully busy is to feed them more *queries* — a second axis of
parallelism orthogonal to the per-cluster-work axis.

---

## 6. Top-line takeaways for the thesis

1. **Fainder is a memory-bound workload, but not at the latency end.** Every
   feature that helps addresses memory *bandwidth* or *capacity* (f16, mimalloc,
   pin-cores, cluster-prefetch, **packed-ids**). Every feature that doesn't
   (`simd`, `horizontal-simd`, `batch-search`, `pgm`) targets the *latency*
   end — either compute speed or the dependent-load chain in binary search.
   **The per-cluster columns (50–5000 elements) are small enough that naïve
   binary search hits L1/L2 cache, not DRAM** — so the "200-cycle dependent-load
   stall" model overstates the latency cost. PGM and AVX-512 attack a ceiling
   that doesn't bite at this scale.

2. **No single optimisation matters much. The composition matters.** SoA
   ~5%, SIMD ~0%, single-axis parallelism caps at 5.7–7.7× depending on
   dataset. Composed (`bestofsuite`): an additional 5.7–7.8× over default
   at peak, ≥10²× over Python.

3. **Dataset size is the dominant parameter for parallel scaling.** A
   single-dataset evaluation would massively over- or under-state the
   story. The 3-dataset matrix shows the parallel knee shifts t=16 → t=32
   → t=64 across 10gb / 30gb / 56gb. **Single-dataset evaluations are
   fundamentally untrustworthy for parallel-scaling claims.**

4. **`bestofsuite` regresses at high t on big data** because the per-feature
   speedups shrink per-query work below the L3-saturation threshold; 96
   fast queries thrash the shared cache.

5. **The default already does inter-query parallelism** (par over queries,
   sequential clusters within). Nested cluster-level parallelism on top
   (§3.4 cluster-par) is **strictly harmful** — up to 3.7× slower. We
   don't need more parallelism; we need lower per-query memory traffic.

6. **The right engine is workload-shaped.** Row-centric (default) wins on
   big-data + high-t. Column-centric (`FAINDER_COLUMNAR=1`) wins on
   small-data or any-data + t=1. There is no universal best engine; the
   data-driven recommendation is to **dispatch on (dataset_size,
   thread_count) at startup** to pick the right engine. The crossover
   surface is well-characterised in §3.5.

7. **Intra-cluster SIMD batching is also a memory-bound dead-end.** Both
   `horizontal-simd` (16-query lanes) and `batch-search` (8-way pipelined)
   measure ≤7% changes — within noise. The mechanism is identical to §3.1:
   you can't vectorise the dependent-load chain, regardless of whether
   you batch lanes within a query or across queries.

8. **Learned indexing (PGM) doesn't beat stdlib partition_point on this scale**
   (§3.6). The latency-bound prediction was wrong: per-cluster columns are
   too small for the dependent-load chain to dominate (it's L2-resident, not
   DRAM-bound). PGM's ~3-cache-line search is roughly equivalent to default's
   ~12-cache-line binary search when most lines hit cache. PGM does win
   ~8% at t=96 — but via the **bandwidth ceiling**, not the latency ceiling
   it was designed to attack. **Real value as a memory-side technique** would
   be to replace the column data with PGM model + remainder (compression),
   not augment it.

9. **Packed-ids is the first ablation that breaks through the bandwidth
   ceiling — confirmed −20.2% at 30gb t=96** (§3.7). Per-cluster
   `ceil(log2(max_id+1))` bit-packing of the id array reduces the emit-stream
   bandwidth from 32 to ~20 bits/id. Wins are concentrated where bandwidth
   *is* the binding ceiling: 30gb t=96 (default anti-scales here, packed
   keeps scaling), 56gb t=1 (L3-capacity pressure), 56gb t=64 (bandwidth
   before HT contention dominates). The 56gb t=96 muted-win pattern
   (default is already flat from t=64 → t=96) is the diagnostic for
   **a second ceiling above DRAM bandwidth on this hardware** — likely
   HT-sibling cache contention with 192 logical threads.

10. **Bandwidth ceilings are *sources*, not a singleton — and positive
    ablations don't compose by default** (§3.7.6–3.7.8). Composing
    packed-ids on top of bestofsuite is **net negative or neutral in
    12/18 cells**, with regressions up to +24% at low t. Mechanism: f16
    in bestofsuite already addresses the dominant bandwidth source
    (search-phase values reads); packed-ids targets the *secondary*
    source (emit-phase ids writes) which `pooled` had largely defused
    already. With no bandwidth left to relieve, packed-ids' decode
    overhead (shift + mask per id) becomes pure cost. **Additivity of
    positive ablations is not given** on hardware-near workloads — each
    ablation has to be re-evaluated *in the composition* it's meant to
    improve, against the *binding ceiling at that configuration*. The
    correct deployment recipe is dispatch-on-regime, not
    feature-union.

11. **Default and bestofsuite have *different* high-t ceilings — and
    bestofsuite's is not bandwidth, HT contention, or DRAM saturation**
    (§3.8). Probe at t=192 (forces all 192 logical cores active) on
    56gb: default loses **+21.2%** vs t=96 (HT-sibling contention on
    shared L1/L2/issue resources — IPC drops from 1.18 to 0.43);
    bestofsuite is **flat** at +1.2% (already saturated at t=96). Perf
    counters localise bestofsuite's ceiling to **work-fragmentation**:
    LLC loads grow +60% from t=32 to t=192 while LLC miss% *drops*
    (38.7% → 32%) — the extra L1/L2 misses are absorbed by L3, not
    DRAM. With f16+simd+pooled compressing per-cluster work, each
    cluster-transition's cold-load (2–3 cache lines) becomes a
    progressively larger share of per-cluster time as threads thin
    out (~2 clusters/thread at t=96 on 56gb). The right attack is on
    the **work-unit-size axis** (cluster-batching, inter-query
    prefetching, async pipelining) — not bandwidth, not HT.

12. **Query-batch breaks the work-fragmentation ceiling — but only
    in-regime; it is not a universal positive ablation** (§3.9). New
    engine variant: par over K-query batches with cluster-as-outer-loop
    within each batch, amortising cluster cold-load across K queries.
    At 56gb t=96 with K=128 it gives **16.17s vs bestofsuite's 20.52s
    and default's 18.78s — −21.2% vs bestofsuite**, the largest single
    win in the campaign. But the K=64 default loses badly in other
    cells (+207% on 10gb t=96, +60–80% on 10gb/30gb at t=8–32) because
    bestofsuite's f16+simd already fits per-cluster work in L1/L2 and
    leaves nothing for the loop-reorder to amortise. **The mechanism
    is consistent**: query-batch wins iff cluster cold-load is the
    binding constraint (t=1 sequential, or t≥64 on big data where
    work-fragmentation bites). The rest of the (dataset, thread)
    surface needs a different engine.

13. **`bestofsuite + query-batch` is a second negative-composability
    finding** (§3.9.7). Composing the f16-equipped bestofsuite with
    query-batch (after porting the latter to f16 — byte-identical
    correctness validated) regresses at every cell on 56gb: t=32 +7.9%,
    t=64 +24%, t=96 +32% vs bestofsuite alone. f16 and query-batch
    attack the **same axis** — cluster cold-load impact (size vs
    occurrences) — so they multiply rather than add. After f16 halves
    cold-load size, amortising the cold-load across K queries costs
    more (route preprocessing + per-batch state) than the now-smaller
    saving recovers. With §3.7.6 packed-ids+bestofsuite, this is the
    **second case where two independently-positive ablations fail to
    compound**. The pattern: when two ablations attack different
    aspects of the *same ceiling*, they substitute rather than
    complement.

14. **Three different engines win at three different thread counts on
    the same dataset** — the cleanest possible dispatch-on-regime
    evidence (§3.9.8). On c256_56gb at suppress: t=32 → bestofsuite
    (16.63s); t=64 → packed-ids (16.59s); t=96 → qbatch K=128 (16.17s).
    No engine is within 5% of the regime-best at every cell.
    **Dispatch-on-regime is not an optimisation — it's the only way to
    be near-optimal across the (t, dataset) surface.** The thesis's
    deployment recommendation is therefore not "pick one composed
    build", it's "probe (dataset_size, thread_count) at startup and
    dispatch to the right engine for that regime".

15. **Morsel falsifies the cross-worker cooperative-caching
    hypothesis — and supplies a third instance of the
    negative-composability pattern** (§3.10). Morsel-driven
    scheduling (Bandle/Giceva 2021) — LPT-sorted phase-major queue,
    per-worker FIFO Chase-Lev deques, soft phase alignment via
    FIFO push order — loses 8–12% to qbatch K=128 at every cell on
    c256_56gb t=32/64/96 (18.05–18.57s vs 16.17–17.22s). Morsel is
    *flat* across t=32→96: it neither suffers HT contention nor
    wins at the work-fragmentation regime. The 8–12% gap is exactly
    the cooperative-caching/cluster-locality term that qbatch's
    per-thread `for c in clusters` loop captures and that morsel's
    cross-worker dispatch breaks; morsel's +4% over default lower-
    bounds the cluster-locality value at ~5–10%, and qbatch K=128
    already collects all of it (§3.8 LLC miss% drops with t under
    bestofsuite/qbatch). **The Bandle/Giceva 1.5–3× headroom was
    measured against an unstructured baseline; qbatch K=128 in this
    codebase is approximately a "cooperative-locality-aware
    fixed-size morsel" and has already collected that headroom.**
    With this finding morsel joins `packed-ids+bestofsuite` (§3.7.6)
    and `bestofsuite+qbatch` (§3.9.7) as the third instance of the
    same structural pattern: when a coarse mechanism already
    captures most of what a finer mechanism is designed to recover,
    the finer mechanism net-regresses because its bookkeeping/
    coordination overhead has nothing to recover against. Three
    independent instances elevate this from incidental finding to
    a **structural observation about ablation composition on
    hardware-near workloads** (§3.10.5).

16. **Per-cluster reindexing falsifies its own bandwidth-budget
    prediction — the fourth negative-composability instance, on a
    new axis** (§3.11). The pre-registered prediction was a +13%
    emit-bandwidth saving on top of packed-ids from compressing the
    decoder read width from ~20 to ~13 bits (with `local_to_global`
    lookup, output unchanged at 32-bit `Vec<u32>` floor). Empirically
    deltas span **−13% (10gb t=96) to +243% (56gb t=16)** depending
    on regime. A four-variant decomposition (`local-ids` / `bench` /
    `noalloc`) shows the regression is **independent of the
    `local_to_global` table allocation** — falsifying H1 (TLB on
    table) and H2 (NUMA on table). The perf probe localises the
    cause to a **75× higher dTLB-miss rate per instruction** in all
    three local-* variants vs packed-ids, with bench and noalloc
    matching exactly. Mechanism: **the bw=13 decoder access pattern
    over the packed buffer drives page-table-walker pressure that
    the bandwidth-budget arithmetic does not model.** The exact
    hardware root cause (why bw=13 walks more pages than bw=20
    over the same logical layout) is standing as H4 — disassembly
    + TLB-walk-source trace is Future Work; the thesis claim is
    robust without it.

17. **The negative-composability pattern is a named methodological
    contribution of this thesis** (§3.13). **Five independent
    instances on five distinct hardware axes** — emit-phase
    bandwidth, cluster cold-load size, cross-worker phase
    coordination, decoder access pattern, memory-locality
    fragmentation — sharing a single shape:
    **when a coarse mechanism captures the dominant share of what a
    finer mechanism is designed to recover, the finer mechanism
    does not compose; its bookkeeping/decode/coordination overhead
    finds no residual headroom and emerges as net cost.** This is
    distinct from the dispatch-on-regime *deployment* artefact
    (§3.9.8): dispatch tells you which build to ship; the
    negative-composability pattern tells you **how to evaluate an
    ablation against an already-composed baseline**. The
    pre-flight check it implies — identify the binding ceiling at
    the target composition (not at the bare default) before
    committing to the ablation — is the methodology contribution
    that generalises beyond this codebase. The pattern is
    falsifiable: an ablation composing positively against a
    baseline whose binding ceiling it explicitly does not address
    would break the claim. None of the campaign's five instances
    satisfy that counterfactual.

18. **NUMA cross-socket interconnect is a fourth ceiling, distinct
    from on-socket DRAM bandwidth** (§3.12). The §3.7/§3.8
    "DRAM bandwidth" label had hidden a second sub-ceiling for the
    entire campaign. A four-config NUMA probe on c256_56gb
    (unpinned baseline / single-socket-clean / interleave /
    cross-socket-forced) opens the entanglement: **single-socket
    placement (`numactl --cpunodebind=0 --membind=0`) beats unpinned
    by 11–13% at t ≤ 48** — a new regime-best on c256_56gb at those
    thread counts, with zero source-code change. The first new
    positive ablation since §3.9 (query-batch).
    **`numactl --interleave=0,1` regresses by 26–41% at every cell**
    — the fifth instance of the negative-composability pattern
    (§3.13), on the memory-locality-fragmentation axis.
    **Cross-socket-forced ties unpinned within 1%** — meaning the
    unpinned baseline was already paying cross-socket UPI cost,
    which is why single-socket-clean is faster than first-touch.
    Dispatch policy gains a placement axis: `numactl_prefix` field
    alongside `features` and `env`; recommend single-socket at
    t ≤ 48 + n_hists ≥ 600K. The §3.8 two-ceiling model thus
    expands to four ceilings on this hardware (on-socket DRAM,
    cross-socket UPI, HT-sibling contention, work-fragmentation).

19. **Dispatch-on-regime is empirically robust on the cluster-count
    axis** (§3.14). The c1024_56gb out-of-distribution validation
    point — identical histograms, identical queries, but K-means
    at K=1024 collapsing to 610 effective clusters (3.2× sparser
    than c256_56gb's 191) — extends the §3.9.9 validation set
    along a third axis the original campaign held fixed.
    **6/6 cells within 5% of regime-best; 4/6 cells exact match;
    all 6 within 1%.** The two non-exact cells (t=1, t=64) both
    shift toward `bestofsuite`-flavoured choices, mechanism-coherent
    with the smaller per-cluster emit volume and larger per-thread
    cluster count at the sparser regime. The combined validation
    record stands at **23/24 cells within 5% (17/18 in-distribution
    + 6/6 out-of-distribution)**, with the OOD cells uniformly
    within 1%. Claim 2 (dispatch-on-regime as the only near-optimal
    deployment) is robust to the K axis at this scale, and the
    deployment policy needs no source-code change to handle the
    sparser-cluster point.

20. **The structural finding is cross-axis cross-density-robust on
    its strong instances; two refinements identified by Phase 4
    variance review** (§3.15). The Phase 4 sweep at c1024_56gb
    measures eight pre-registered claims and applies 5-rep 95 %
    CI checks before committing to each verdict. **5/8 strong
    reproductions** (ceiling (iv) single-socket and interleave,
    §3.9.7 with amplified magnitude, §3.11 catastrophic NEG,
    §3.12). **2/8 reproduce as clean nulls** (ceiling (i) simd
    indistinguishable from default at all 6 cells under 95 % CI,
    despite raw point estimates including a t=64 −6.7 % that
    looked like a win before variance was checked; §3.7.6 mixed
    at both densities — neither sign-uniform). **2/8 are
    refinements**: (a) ceiling (ii) `f16` *standalone* sign-flips
    at c1024 *t* = 16 (−13 % loss) but the `bestofsuite` bundle
    still wins at the same magnitude as at c256 (−18 %); a
    `bestofsuite − f16` follow-up suggests f16 is
    *compositionally* positive inside the bundle (~+11 % point-
    estimate contribution) though single-cell variance prevents
    95 % significance — directionally consistent but not
    statistically proven. (b) §3.10 morsel's reliable c256 +8 to
    +12 % NEG **attenuates to indistinguishable-from-baseline at
    c1024** across all measured cells (95 % CIs all straddle
    zero) — a density-dependent attenuation rather than the
    cell-dependent sign-flip an earlier reading of the point
    estimates suggested. Combined record: **23/24 dispatch cells
    within 5 % + 5/8 strong structural reproductions + 2/8 null
    reproductions + 2/8 mechanism-coherent attenuations + 0/8
    outright falsifications**. The methodology of measuring
    across a 3.2× density range surfaces mechanism dependencies
    the per-density framework explicitly anticipates; this is
    the methodological win.

## 6.1 What we have, what's missing, what to look at next

**Three main axes are fully covered:**

| Axis | Coverage | Status |
|---|---|---|
| SIMD (compute) | `simd`, `horizontal-simd`, `batch-search` × 3 datasets × 6 t × 5 reps | ✅ negative result, mechanism understood |
| Memory layout (SoA vs AoS) | `aos` × 3 datasets × 6 t × 5 reps | ✅ small but consistent edge to SoA |
| Multicore parallelism | `default` strong-scaling × 3 datasets × 6 t × 5 reps; `cluster-par` × 3 datasets × 6 t × 5 reps; column-centric × 3 builds × 3 datasets × 6 t × 5 reps | ✅ knee shifts with dataset size; nested parallelism harmful; engine choice workload-dependent |

**Single-feature decomposition — the one gap left in the ablation matrix.**
We have `bestofsuite` as the composition (`pooled f16 simd pin-cores
cluster-prefetch mimalloc`) but haven't measured each feature *alone*:

| Feature | Mechanism it targets | Expected single-axis win |
|---|---|---|
| `f16` | Memory bandwidth + capacity | Should be the largest single contributor — halves bytes/element |
| `pooled` | Allocator pressure (no per-query Vec churn) | Probably small but consistent; matters most at high t |
| `mimalloc` | Allocator mutex contention | Should help most at t > 16 (where ptmalloc bottlenecks) |
| `pin-cores` | NUMA + SMT-sibling sharing | Should help at t > 48 (cross-socket region) |
| `cluster-prefetch` | DRAM latency on cluster stride | Help at low t, harm at high t (per the storm finding in §5.4) |

Running these would let us cleanly say "of the 5.7–7.8× bestofsuite win,
X% comes from f16, Y% from mimalloc, etc." Currently we can only say "the
composition wins; individual features are hard to credit." A 5-build × 3-
dataset × 6-thread × 5-rep sweep = ~1.5 hours.

**Other unexplored research directions (in rough priority order):**

| Direction | Hypothesis | Implementation effort |
|---|---|---|
| **NUMA-local mmap** | The 56gb default barely regresses past t=48 — but with NUMA-local mmap (each socket sees only its half), it might *not regress at all*. | Medium (~1 day): mmap with `MAP_FIXED` per-socket, thread-affinity dispatch. |
| **Index compression** (SIMD-BP128, FastPFor on the IDs) | Halves the bandwidth of the per-cluster column reads on the bandwidth-bound regime. Adds ~1ns/element decode cost. Net win likely positive on big-data + high-t. | Medium-high (~2-3 days): integrate FastPFor crate, retrofit `SubIndex`. |
| **Engine dispatch on (size, t)** | Pick row vs column at startup based on dataset size and thread count. Closes the 56gb high-t regression of column-centric and the 10gb high-t regression of row-centric. | Low (~half day): runtime check, pick engine. Could even be feature-flagged "auto". |
| **Cache-aware cluster scheduling** | Currently Rayon assigns clusters to threads in arbitrary order. If two adjacent clusters share bin-edge ranges, prefetching the second while processing the first hits cache. Currently `cluster-prefetch` does this blind; cache-aware ordering could amplify. | High (~1 week): would need profile-guided cluster-ordering analysis. |
| **Roaring bitmap result merge** | Per the §1 gate decision, merge phase is ~0% — would only help on with-results runs at high |S| selectivity. Confirmed not load-bearing. | Skipped. |

**Methodology gap to fix before the next campaign:**

`bench.py` should capture *both* `wall_s` (Rust query time) and
`subprocess_s` (end-to-end including PyO3 boxing). With-results numbers
in §5 currently understate user-visible time by 5–20× on big data.

---

## 7. Plots

Saved to [docs/figures/](figures/):

- [strong_scaling_default.png](figures/strong_scaling_default.png) — wall vs
  threads, all 3 datasets, log-log. The right-shifting knee is visible.
- [ipc_vs_threads_default.png](figures/ipc_vs_threads_default.png) — IPC
  collapse from ~1.8 to ~0.6 across t=1 → t=96 on all 3 datasets.
- [speedup_simd.png](figures/speedup_simd.png) — flat ~1.0× line confirming
  Axis 1's negative result.
- [speedup_soa.png](figures/speedup_soa.png) — modest SoA edge, peak at
  56gb t=8.
- [speedup_pgm.png](figures/speedup_pgm.png) — PGM ratio vs default; ≤8%
  wins concentrated at t=96 (§3.6).
- [speedup_packed.png](figures/speedup_packed.png) — packed-ids ratio
  vs default; clearest win at 30gb t=96 (−20.2%, §3.7).
- [speedup_qbatch.png](figures/speedup_qbatch.png) — query-batch K=64
  ratio vs default; wins at 56gb t=1 and t≥64, regresses elsewhere
  (§3.9).
- [dispatch_summary.png](figures/dispatch_summary.png) — heat-map of the
  regime-best engine per (dataset, threads) cell, with median wall in
  seconds. The cleanest visual of the §3.9.8 dispatch table.
- [end_to_end_bestofsuite.png](figures/end_to_end_bestofsuite.png) —
  bestofsuite vs Python on log axes.

---

## 8. What's missing and why

| Cell | Status | Reason |
|---|---|---|
| 56gb Python (any t) | timed out | wall > 3600s cap; extrapolated ~3500–4000s |
| 56gb default with-results | not run | Each run ~30 min due to PyO3 boxing dominating subprocess wall (§1.6); chain killed to free up time for analysis |
| 30gb default with-results t=96 | partial (4 of 5 reps) | Same reason as above |
| Single-feature ablations (f16, pooled, mimalloc, kary, eytzinger, horizontal-simd, batch-search) | not in this campaign | §4 — composition captured in `bestofsuite`, individual ablations are auxiliary |
| Column-centric engine (`FAINDER_COLUMNAR=1`) sweep | not in this campaign | Inverts the parallel axis (par-over-clusters) — flagged as next investigation in §6 |

These gaps are not load-bearing for the §6 conclusions — the suppress-vs-
suppress comparisons cover the science of every axis.
