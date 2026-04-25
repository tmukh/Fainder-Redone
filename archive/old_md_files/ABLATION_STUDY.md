# Ablation Study Design & Methodology

This document defines the structure and methodology for the Fainder optimization ablation study. An ablation study systematically disables each optimization to measure its individual contribution to the final 18x speedup.

## Overview

The Fainder system combines four major optimizations:
1. **Memory Layout**: Structure of Arrays (SoA) vs Array of Structs (AoS)
2. **Parallelization**: Rayon parallel execution vs serial execution
3. **Search Algorithm**: partition_point vs binary_search
4. **Index Mode**: Rebinning vs Conversion

This ablation study methodology allows us to quantify the contribution of each.

---

## Ablation Axis 1: Memory Layout (SoA vs AoS)

### Description

**SoA (Current Implementation)**:
- Percentile values and histogram indices are stored in separate arrays
- Enables sequential access during binary search
- Better cache locality for L1/L2 caches
- Location: `src/index.rs`, `SubIndex` struct (lines 1-30)

**AoS (Alternative)**:
- Values and indices are interleaved in a single array: `[(val0, idx0), (val1, idx1), ...]`
- Traditional memory layout, easier to reason about
- May cause cache misses during search due to index field pollution

### Memory Layout Comparison

```
Current (SoA):
┌─────────────────────────────┐
│ values: [f32, f32, ...f32]  │  ← Sequential f32 loads
│ indices: [u32, u32, ...u32] │
└─────────────────────────────┘

Alternative (AoS):
┌──────────────────────────────────────┐
│ data: [(f32,u32), (f32,u32), ...]    │  ← Interleaved loads
└──────────────────────────────────────┘
```

### Enabling/Disabling SoA

**Location**: `src/index.rs`, lines 99-123

**To Test AoS**:
1. Modify `SubIndex` struct to use single interleaved Vec
2. Update flattening logic (lines 116-128) to interleave data
3. Update access in `src/engine.rs` lines 199-220 to dereference interleaved data
4. Rebuild with `cargo build --release`

### Expected Impact

| Aspect | Measurement |
|--------|------------|
| L1 Cache Hit Rate | SoA should be 5-10% better |
| L2 Cache Hit Rate | SoA should be 2-5% better |
| Memory Throughput | SoA benefits from prefetcher (sequential) |
| Execution Time | SoA should be 20-30% faster |

### Profiling Commands

```bash
# Profile SoA (current)
perf stat -e L1-dcache-load-misses,L1-dcache-loads,LLC-loads,LLC-load-misses \
  ./target/release/run-queries [query args]

# After switching to AoS:
perf stat -e L1-dcache-load-misses,L1-dcache-loads,LLC-loads,LLC-load-misses \
  ./target/release/run-queries [query args]
```

---

## Ablation Axis 2: Parallelization (Rayon vs Serial)

### Description

**Rayon Parallel (Current)**:
- Uses `par_iter()` to distribute queries across CPU cores
- Each query processed independently (embarrassingly parallel)
- No GIL contention (Rust execution)
- Work-stealing scheduler for load balancing
- Location: `src/engine.rs`, lines 88-236

**Serial Execution (Alternative)**:
- Uses standard `iter()` instead of `par_iter()`
- All queries executed sequentially
- Establishes baseline for parallelization overhead

### Parallelization Impact

On an N-core system:
- Serial: ~1x (baseline)
- Parallel: Expected ~N-fold speedup (minus coordination overhead)
- On 8-core system: Expect 7-8x speedup

### Enabling/Disabling Rayon

**Location**: `src/engine.rs`, lines 88-90

**To Test Serial**:
```rust
// Current (Rayon):
let results: Vec<Vec<u32>> = typed_queries
    .par_iter()  // ← Change to iter()
    .map(|q| { ... })
    .collect();
```

**Via Feature Flag (Recommended)**:
1. Add to `Cargo.toml`:
   ```toml
   [features]
   default = ["parallel"]
   parallel = ["rayon"]
   ```

2. In `src/engine.rs`:
   ```rust
   #[cfg(feature = "parallel")]
   let results: Vec<Vec<u32>> = typed_queries.par_iter().map(...).collect();

   #[cfg(not(feature = "parallel"))]
   let results: Vec<Vec<u32>> = typed_queries.iter().map(...).collect();
   ```

3. Build commands:
   ```bash
   cargo build --release --features parallel     # Parallel
   cargo build --release --no-default-features   # Serial
   ```

### Expected Impact

| Aspect | Measurement |
|--------|------------|
| Speedup on 8 cores | 7-8x |
| Speedup on 16 cores | 14-16x |
| Overhead per query | <5% (work-stealing cost) |

### Profiling Commands

```bash
# Parallel execution
time ./target/release/run-queries [query args] --workers 8

# Serial execution (after rebuild)
time ./target/release/run-queries [query args] --workers 1
```

---

## Ablation Axis 3: Search Algorithm (partition_point vs binary_search)

### Description

**partition_point (Current)**:
- Uses simple boolean predicate: `|x| x < ref`
- Better branch prediction (single comparison per iteration)
- Exact match with Python `np.searchsorted(..., "left")`
- Location: `src/engine.rs`, lines 179-185 and 218-229

**binary_search (Alternative)**:
- Uses three-way comparison: `Ordering::Less | Equal | Greater`
- More complex predicate
- Requires handling Ok/Err branches

### Search Algorithm Comparison

```
partition_point: Fewer branches, simpler predicate
├─ Branch 1: if (x < ref) { continue } else { return idx }
└─ Impact: ~95% branch prediction accuracy

binary_search: Three-way comparison
├─ Branch 1: if (cmp == Less) { continue left }
├─ Branch 2: if (cmp == Equal) { return idx }
└─ Branch 3: if (cmp == Greater) { continue right }
└─ Impact: ~85-90% branch prediction accuracy
```

### Enabling/Disabling partition_point

**Location**: `src/engine.rs`, lines 179-229

**To Test binary_search**:
```rust
// Replace:
let pp = bins.partition_point(|&x| x < ref_val);
let raw_bin_idx = if pp == 0 { 0 } else { pp - 1 };

// With:
let search_result = bins.binary_search_by(|x| {
    if x < &ref_val { Ordering::Less }
    else if x > &ref_val { Ordering::Greater }
    else { Ordering::Equal }
});
let raw_bin_idx = match search_result {
    Ok(i) => i,
    Err(i) => if i > 0 { i - 1 } else { 0 },
};
```

### Expected Impact

| Aspect | Measurement |
|--------|------------|
| Branch Miss Rate | partition_point ~3-5% better |
| L1 Instruction Cache | partition_point more compact |
| Execution Time | partition_point 2-5% faster |

### Profiling Commands

```bash
# Current (partition_point)
perf stat -e branch-misses,branches,cycles \
  ./target/release/run-queries [query args]

# After switching to binary_search:
perf stat -e branch-misses,branches,cycles \
  ./target/release/run-queries [query args]
```

---

## Ablation Axis 4: Index Mode (Rebinning vs Conversion)

### Description

**Rebinning Mode**:
- Single variant per cluster (pctl_mode and bin_mode unused)
- Faster construction
- May have lower query accuracy
- Uses: `index.get_subindex(c, 0)`

**Conversion Mode**:
- Multiple variants per cluster (rebinning + conversion)
- Slower construction
- Better query accuracy
- Uses: `index.get_subindex(c, 0)` and `index.get_subindex(c, 1)`

### Index Mode Configuration

```python
# Python side (fainder/index.py construction):
# Rebinning: variants = [[subindex0]]  (1 variant)
# Conversion: variants = [[subindex0, subindex1]]  (2 variants)
```

### Enabling/Disabling Conversion

**Location**: Index constructed in Python, queried in Rust

**To Test**:
1. Build index with conversion mode (Python side)
2. Run query (Rust automatically detects with `index.get_subindex(c, 1).is_some()`)

### Expected Impact

| Aspect | Measurement |
|--------|------------|
| Query Accuracy | Conversion 5-10% better |
| Execution Time | Rebinning 10-15% faster (one variant) |
| Memory Usage | Rebinning uses 50% less memory |

### Profiling Commands

```bash
# Build and query with rebinning
python -c "from fainder import Fainder; f = Fainder(...); f.index('rebinning')"
time ./target/release/run-queries -i data/rebinning_index.zst ...

# Build and query with conversion
python -c "from fainder import Fainder; f = Fainder(...); f.index('conversion')"
time ./target/release/run-queries -i data/conversion_index.zst ...
```

---

## Full Ablation Matrix

Running all combinations:

```
Configuration                          | Expected Speedup
────────────────────────────────────────────────────────
Baseline (Python)                      | 1.0x
+ SoA layout                           | ~1.25x
+ Rayon parallelization                | ~8-16x (depends on cores)
+ partition_point                      | ~1.05x
+ Conversion mode                      | ~0.9x (may reduce speed)
────────────────────────────────────────────────────────
Total (SoA + Rayon + partition_point)  | 18x (achieved)
```

---

## Measurement Methodology

### 1. Dataset Selection

Use `eval_medium` for consistent benchmarking:
```bash
-i data/eval_medium/indices/best_config_rebinning.zst
-q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst
```

### 2. Time Measurement

```bash
# Use shell time for wall-clock time
time ./target/release/run-queries [args]

# Or use Rust's built-in timing (if logged)
# Look for "Ran X queries in Y seconds" in logs
```

### 3. Warm-Up Runs

Run each configuration at least twice:
- First run: JIT/cache effects
- Second run: Stable measurement (use this one)

### 4. Statistical Treatment

For each configuration:
- Run N=3 times
- Report: median time, min/max time, std deviation

---

## Implementation Checklist

- [ ] Task 3.1: Create AoS variant with feature flag
- [ ] Task 3.2: Create serial variant with feature flag
- [ ] Task 3.3: Create ablation_benchmark.sh script
- [ ] Task 3.4: Run benchmarks and collect results
- [ ] Task 3.5: Create analysis notebook with plots
- [ ] Task 3.6: Document findings in ABLATION_RESULTS.md

---

## Expected Outputs

After running the full ablation study, we should have:

1. **CSV Results** (`logs/ablation_study/results.csv`):
   ```
   configuration,dataset,execution_time_s,memory_mb,cache_misses
   soa_parallel_partition,eval_medium,2.3,150,3.2%
   aos_parallel_partition,eval_medium,2.8,150,5.1%
   soa_serial_partition,eval_medium,18.5,150,3.2%
   ...
   ```

2. **Plots**:
   - Execution time comparison bar chart
   - Memory usage by configuration
   - Cache miss rate comparison

3. **Analysis Document** (`ABLATION_RESULTS.md`):
   - Findings from each ablation axis
   - Statistical significance
   - Recommendations for production

---

## References

- Thesis Section 4.2: Cache Hierarchy Optimization
- VLDB Paper Fig 5: Cache Efficiency Profiling
- VLDB Paper Fig 6: Parallelization Scaling
