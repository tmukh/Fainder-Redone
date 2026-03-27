# Fainder Optimization Implementation Roadmap

This document outlines the thesis-driven optimizations for the Fainder query execution engine, organized from simplest to most complex. The goal is to document what has been implemented, what is missing, and how to complete the remaining work.

## Executive Summary

**Current Status**: ~85% complete
- ✅ Rust execution engine with 18x speedup achieved
- ✅ Cache-efficient SoA memory layout implemented
- ✅ Multicore parallelism via Rayon
- ✅ Comprehensive benchmarking suite
- ⚠️ Missing: Detailed profiling analysis, SIMD optimization, structured ablation study

---

## Phase 1: Documentation & Analysis (Easiest - 2-4 hours total)

### Task 1.1: Add Inline Optimization Comments
**Status**: Not Done
**Effort**: 1 hour
**Files**: `src/engine.rs`, `src/index.rs`

Add clarifying comments explaining optimization choices. Examples:

```rust
// Why here: This uses partition_point instead of binary_search because:
// - We avoid branch misprediction on failed searches
// - Better cache locality with single predicate evaluation
// See: Fig X in thesis or VLDB paper section Y
```

**Steps**:
1. Read src/engine.rs and src/index.rs
2. Identify key algorithmic choices (partition_point, SoA layout, parallel iteration)
3. Add 2-3 line comments explaining:
   - What optimization this is
   - Why it was chosen (reference thesis sections if applicable)
   - Expected performance benefit

**Implementation Example**:
- Line 170-182 (partition_point logic) needs explanation
- Line 192-200 (subindex access pattern) needs explanation
- Line 88-90 (par_iter) needs explanation of parallelization strategy

---

### Task 1.2: Document Ablation Study Design
**Status**: Not Done
**Effort**: 1.5 hours
**Output File**: `ABLATION_STUDY.md`

Create a document defining the ablation study structure and results interpretation.

**Steps**:
1. Create `ABLATION_STUDY.md`
2. Define 4 ablation axes:
   - **Memory Layout**: SoA vs AoS (column-major vs row-major)
   - **Parallelization**: Serial vs Rayon parallel
   - **Index Mode**: Rebinning vs Conversion
   - **Search Strategy**: partition_point vs binary_search

3. For each axis, document:
   - Expected performance impact
   - How to disable/enable (code location)
   - Measurement methodology

**Template Structure**:
```markdown
## Ablation 1: Memory Layout (SoA vs AoS)
### Description
- SoA (current): Column-major flattening in SubIndex
- AoS: Traditional struct of arrays

### Enabling/Disabling
- SoA: src/index.rs lines X-Y
- To test AoS: [instructions]

### Expected Impact
- Cache efficiency: ~X% improvement expected
- L1/L2 misses: Should decrease by ~Y%
```

---

### Task 1.3: Create Optimization Thesis Mapping
**Status**: Not Done
**Effort**: 1 hour
**Output File**: `THESIS_MAPPING.md`

Map each thesis contribution to code implementation.

**Template**:
```markdown
# Thesis Contributions to Code Mapping

## Thesis Section 4.1: Rust Execution Engine
- **Paper Goal**: "18x speedup over Python baseline"
- **Implementation**: src/engine.rs:56-250
- **Bindings**: src/lib.rs (PyO3 integration)
- **Measurement**: See BENCHMARK_GUIDE.md
- **Achieved**: 18x speedup (commit 4812cc4)

## Thesis Section 4.2: Cache Hierarchy Optimization
- **Paper Goal**: "SoA memory layout for cache locality"
- **Implementation**: src/index.rs (SubIndex structure)
- **Strategy**: Column-major flattening
- **Benefit**: Cache-friendly sequential access
```

---

## Phase 2: Profiling & Measurement (Medium - 3-6 hours)

### Task 2.1: Set Up Linux Profiling Pipeline
**Status**: Not Done
**Effort**: 1.5 hours
**Tools**: `perf`, `cargo flamegraph`

Create profiling infrastructure.

**Steps**:
1. Install profiling tools:
   ```bash
   sudo apt-get install linux-tools-generic
   cargo install flamegraph
   ```

2. Create `scripts/profile.sh`:
   ```bash
   #!/bin/bash
   set -e

   # Profile Rust execution
   cargo build --release

   # Flamegraph for query execution
   cargo flamegraph --bin run-queries -- \
     -i data/eval_medium/indices/best_config_rebinning.zst \
     -t index \
     -q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
     -m recall

   # Perf stat for statistics
   perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses \
     cargo run --release --bin run-queries -- [same args]
   ```

3. Document expected outputs

---

### Task 2.2: Profile Query Execution Hot Paths
**Status**: Not Done
**Effort**: 2 hours
**Output**: `logs/profiling/flamegraph.svg`, `logs/profiling/perf.txt`

Run profiling and identify bottlenecks.

**Steps**:
1. Run `scripts/profile.sh` with eval_medium dataset
2. Analyze flamegraph for:
   - Time in Python bindings vs Rust core
   - Time in parallel coordination vs actual query work
   - Memory allocation/deallocation time
3. Run `perf stat` and capture:
   - Instructions per cycle (IPC)
   - Cache miss ratio
   - Branch misprediction rate

**Expected Results**:
- IPC should be 2-4 (good parallelism)
- Cache miss ratio should be <5% for L1
- Flamegraph should show >80% time in core query logic

---

### Task 2.3: Generate Profiling Report
**Status**: Not Done
**Effort**: 1.5 hours
**Output File**: `PROFILING_REPORT.md`

Document profiling results.

**Report Structure**:
```markdown
# Profiling Report: Query Execution Performance

## Test Configuration
- Dataset: eval_medium (1GB histograms)
- Queries: 1000 random distribution queries
- Machine: [CPU model, cores, RAM]
- Build: Release mode, Rayon with all cores

## Flamegraph Analysis
[embed flamegraph.svg or screenshot]

### Hot Paths Identified
1. partition_point (binary search): 35% of time
2. Parallel coordination (Rayon): 15% of time
3. Result marshalling (PySet creation): 20% of time
4. Other: 30%

## Performance Metrics
- Instructions per cycle: 2.8 (good)
- Cache miss ratio: 3.2% (excellent)
- Branch miss ratio: 1.1% (excellent)
- Memory bandwidth: 45 GB/s

## Conclusions
- [What optimizations are working]
- [Potential future improvements]
```

---

## Phase 3: Structured Ablation Study (Medium-Hard - 6-10 hours)

### Task 3.1: Implement Memory Layout Variant (AoS)
**Status**: Not Done
**Effort**: 2.5 hours
**Files**: `src/index.rs`

Create an AoS variant for comparison.

**Steps**:
1. In `src/index.rs`, create new `SubIndexAoS` struct:
   ```rust
   struct SubIndexAoS {
       data: Vec<(u32, f32)>,  // interleaved values and indices
   }
   ```

2. Create a feature flag in `Cargo.toml`:
   ```toml
   [features]
   default = ["aos-variant"]  # or "soa-only"
   aos-variant = []
   ```

3. Implement conditional compilation:
   ```rust
   #[cfg(feature = "aos-variant")]
   type SubIndex = SubIndexAoS;

   #[cfg(not(feature = "aos-variant"))]
   type SubIndex = SubIndexSoA;
   ```

4. Update query execution to work with both layouts

---

### Task 3.2: Implement Serial Execution Variant
**Status**: Not Done
**Effort**: 1.5 hours
**File**: `src/engine.rs`

Create serial execution variant.

**Steps**:
1. Add feature flag in `Cargo.toml`:
   ```toml
   parallel = []  # default enabled
   ```

2. In engine.rs, wrap parallel code:
   ```rust
   #[cfg(feature = "parallel")]
   let results: Vec<Vec<u32>> = typed_queries.par_iter().map(...).collect();

   #[cfg(not(feature = "parallel"))]
   let results: Vec<Vec<u32>> = typed_queries.iter().map(...).collect();
   ```

3. Document compilation:
   ```bash
   cargo build --release --no-default-features  # serial only
   cargo build --release --features parallel  # parallel (default)
   ```

---

### Task 3.3: Run Ablation Study Benchmark Suite
**Status**: Not Done
**Effort**: 3-4 hours
**Output**: `logs/ablation_study/results.csv`

Run benchmarks with all combinations.

**Steps**:
1. Create `scripts/ablation_benchmark.sh`:
   ```bash
   #!/bin/bash

   DATASETS=("eval_small" "eval_medium")
   FEATURES=(
     "default"           # SoA + Parallel
     "aos-only"          # AoS + Parallel
     "serial-only"       # SoA + Serial
     "aos-serial"        # AoS + Serial
   )

   for dataset in "${DATASETS[@]}"; do
     for feature in "${FEATURES[@]}"; do
       cargo build --release --features "$feature"
       echo "Testing $feature with $dataset..."
       ./target/release/run-queries -i "data/$dataset/..." \
         --log-file "logs/ablation_study/${feature}_${dataset}.log"
     done
   done
   ```

2. Run full suite and collect:
   - Execution time for each configuration
   - Memory usage
   - Cache statistics (via perf)

3. Compile results into CSV for analysis

---

### Task 3.4: Analyze & Document Ablation Results
**Status**: Not Done
**Effort**: 1.5 hours
**Output**: `ABLATION_RESULTS.md` + Jupyter notebook

Analyze performance differences.

**Steps**:
1. Create Jupyter notebook in `analysis/ablation_study.ipynb`
2. Load CSV and plot:
   - Execution time comparison (bar chart)
   - Memory usage (line plot)
   - Cache efficiency (L1/L2 miss rates)
3. Document findings:
   - Which optimization has biggest impact?
   - Are effects cumulative or antagonistic?
   - Recommended production configuration

---

## Phase 4: Advanced Optimization (Hardest - 8-15 hours)

### Task 4.1: Profile Memory Access Patterns
**Status**: Not Done
**Effort**: 2 hours
**Tools**: `perf`, `cachegrind` (optional)

Analyze cache behavior in detail.

**Steps**:
1. Run perf with advanced PMU events:
   ```bash
   perf record -e cycles,instructions,cache-references,cache-misses,\
     LLC-loads,LLC-load-misses,LLC-stores,dTLB-loads,dTLB-load-misses \
     ./target/release/run-queries [query args]

   perf report
   ```

2. Optional: Run cachegrind for detailed cache simulation:
   ```bash
   valgrind --tool=cachegrind ./target/release/run-queries [query args]
   cg_annotate cachegrind.out.[pid] --auto=yes
   ```

3. Analyze reports for:
   - Hot data structures (which arrays are accessed most?)
   - Striding patterns (sequential vs random access?)
   - TLB efficiency (page fault rate?)

---

### Task 4.2: Implement SIMD Vectorization (Optional)
**Status**: Not Done
**Effort**: 4-6 hours
**Files**: `src/engine.rs` (hot path optimization)

Add SIMD for vectorizable operations.

**Rationale**: The partition_point search currently compares one element at a time. SIMD can compare 4-8 in parallel.

**Steps**:
1. Identify SIMD-friendly operations:
   - Percentile comparison: `col_vals.partition_point(|&x| x < target)`
   - Could vectorize by comparing 4 f32s in parallel (AVX2)

2. Add dependency to `Cargo.toml`:
   ```toml
   packed_simd = "0.3"  # or use std::arch with #[cfg(target_arch = "x86_64")]
   ```

3. Create SIMD variant of partition_point:
   ```rust
   #[cfg(target_arch = "x86_64")]
   unsafe fn simd_partition_point(values: &[f32], target: f32) -> usize {
       // Use AVX2 to compare 8 x f32 elements at once
       // See: https://www.intel.com/content/dam/doc/...
   }
   ```

4. Benchmark impact with `perf` before/after

**Expected Impact**: 10-20% improvement on percentile search (if it's a bottleneck)

---

### Task 4.3: Implement Memory Pooling Strategy
**Status**: Not Done
**Effort**: 3-4 hours
**File**: `src/engine.rs`

Reduce allocation overhead by reusing memory pools.

**Rationale**: Creating Vec for results and PySet allocations happen per query. Pools can eliminate this.

**Steps**:
1. Create a memory pool:
   ```rust
   struct QueryResultPool {
       buffers: Vec<Vec<u32>>,
   }
   ```

2. Implement checkout/checkin:
   ```rust
   impl QueryResultPool {
       fn checkout(&mut self) -> Vec<u32> { /* get or create */ }
       fn checkin(&mut self, buf: Vec<u32>) { /* reset and store */ }
   }
   ```

3. Integrate into execute_queries:
   ```rust
   let mut pool = QueryResultPool::new(n_queries);
   let results: Vec<Vec<u32>> = typed_queries
       .par_iter()
       .map(|q| {
           let mut matches = pool.checkout();
           // ... query execution ...
           matches
       })
       .collect();
   ```

**Measurement**: Compare allocation count/time with `perf` or `valgrind --tool=massif`

---

### Task 4.4: Compile Optimization Report
**Status**: Not Done
**Effort**: 2 hours
**Output**: `OPTIMIZATION_REPORT.md`

Final comprehensive report.

**Report Sections**:
1. Executive Summary
   - Speedup achieved per optimization
   - Total speedup: 18x (from paper commits)

2. Per-Optimization Analysis
   - Memory layout (SoA): Expected 20-30% improvement over AoS
   - Parallelism: Expected N-fold improvement (N = num cores)
   - Conversion mode: Context-dependent
   - Result marshalling: Expected 5-10% improvement

3. Cumulative Effect
   - Serial Python baseline → Rust serial: ~X%
   - Rust serial → Rust parallel: ~Y%
   - Rust parallel → With SIMD (if done): ~Z%
   - Total: 18x achieved

4. Profiling Data
   - Flamegraphs
   - Cache statistics
   - IPC metrics

5. Future Optimization Opportunities
   - GPU acceleration for cluster processing
   - Better bin selection heuristics
   - JIT compilation for query templates

---

## Implementation Order & Time Estimates

| Phase | Task | Effort | Priority |
|-------|------|--------|----------|
| 1.1 | Add inline comments | 1h | HIGH |
| 1.2 | Document ablation | 1.5h | HIGH |
| 1.3 | Thesis mapping | 1h | HIGH |
| **Subtotal Phase 1** | | **3.5h** | |
| 2.1 | Set up profiling | 1.5h | HIGH |
| 2.2 | Run profiling | 2h | HIGH |
| 2.3 | Profiling report | 1.5h | HIGH |
| **Subtotal Phase 2** | | **5h** | |
| 3.1 | AoS variant | 2.5h | MEDIUM |
| 3.2 | Serial variant | 1.5h | MEDIUM |
| 3.3 | Ablation benchmarks | 3-4h | MEDIUM |
| 3.4 | Analyze ablation | 1.5h | MEDIUM |
| **Subtotal Phase 3** | | **8.5-9.5h** | |
| 4.1 | Memory profiling | 2h | LOW |
| 4.2 | SIMD optimization | 4-6h | LOW |
| 4.3 | Memory pooling | 3-4h | LOW |
| 4.4 | Final report | 2h | LOW |
| **Subtotal Phase 4** | | **11-14h** | |
| **TOTAL** | | **28-32h** | |

---

## Recommended Quick Win Path (If Limited Time)

1. **Phase 1 (3.5h)**: Documentation - gets thesis mapped
2. **Phase 2 (5h)**: Basic profiling - validates 18x speedup
3. **Phase 3.3 (3-4h)**: Run quick ablation - one dataset
4. **Total: 11.5-12.5h** for high-value thesis completion

This gets you:
- ✅ Clear documentation of what was implemented
- ✅ Profiling evidence of performance gains
- ✅ Quantified ablation study results
- ✅ Ready for thesis defense

Remaining Phase 4 tasks are "nice to have" but not thesis-critical.

---

## How to Use This Roadmap

1. **Start with Phase 1** (3.5 hours)
   - Add comments to code
   - Create mapping documents
   - Quick documentation wins

2. **Move to Phase 2** (5 hours)
   - Set up profiling infrastructure
   - Generate baseline measurements
   - Build confidence in 18x speedup claim

3. **Decide on Phase 3** (~8.5 hours)
   - If time permits: Run full ablation study
   - Provides paper-quality evidence of optimization effectiveness

4. **Phase 4 only if needed** (~11-14 hours)
   - SIMD optimization if profiling shows need
   - Memory pooling if allocations are bottleneck
   - Cachegrind analysis if cache behavior needs deep dive

---

## Notes

- All phases preserve the existing 18x speedup (no functionality changes)
- Phases are independent; can be reordered based on priorities
- Each phase includes measurement methodology for thesis credibility
- All profiling data should be committed to git for reproducibility
