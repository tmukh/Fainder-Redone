# Ablation Study Plan - Fainder Rust Optimization

**Goal**: Understand which optimizations contribute how much to achieve 6.66x speedup

**Strategy**: Implement 5 optimization axes as toggleable feature flags in Rust, then benchmark systematically.

---

## Optimization Axes Identified

### AXIS 1: Language (Rust vs Python)
- **Cost**: Already paid - no additional work
- **Benefit to measure**: Python GIL overhead + interpretation
- **Flag**: `use_python_backend` (use slower ctypes/FFI calls)
- **Expected contribution**: ~2-3x (initialization, GIL contention, type checking)

### AXIS 2: Parallelization Strategy
- **Current**: Rayon work-stealing parallelization (lines 88-89 in engine.rs)
- **Alternatives to test**:
  - Serial execution (no parallelization)
  - Rayon with fixed thread pool size
  - Rayon with parallel chunks of queries
- **Flag**: `parallelization_mode` (serial, rayon, rayon_chunked)
- **Expected contribution**: ~4-8x (queries scale linearly with cores on 8-16 cores, we have 192!)
- **Note**: This will be HUGE because Rayon is doing most of the work

### AXIS 3: Memory Layout (SoA vs AoS)
- **Current**: Structure of Arrays (values[] and indices[] separate, lines 15-20 in index.rs)
- **Alternative**: Array of Structs (store (f32, u32) pairs together)
- **Flag**: `use_soa_layout` (true/false)
- **Expected contribution**: ~1.2-1.3x (20-30% cache efficiency)
- **Implementation**: Store both values and indices in paired struct, adjust access patterns

### AXIS 4: Memory Access Pattern (Column-major vs Row-major)
- **Current**: Column-major flattening (lines 112-129 in index.rs)
- **Alternative**: Row-major flattening (iterate h first, then b)
- **Flag**: `use_column_major_layout` (true/false)
- **Expected contribution**: ~1.05-1.15x (prefetching + TLB)
- **Note**: Usually combined with SoA; might not be independent

### AXIS 5: Search Algorithm (partition_point vs binary_search)
- **Current**: partition_point with custom predicates (lines 170-227 in engine.rs)
- **Alternative**: Standard binary_search_by
- **Flag**: `use_partition_point` (true/false)
- **Expected contribution**: ~1.02-1.05x (2-5% branch prediction improvement)
- **Implementation**: Replace partition_point calls with binary_search equivalents

---

## Systematic Ablation Plan

**Benchmark Matrix** (6 key configurations):

```
┌─────────┬────────────┬──────────┬───────────┬──────────────┬─────────────┐
│ Config  │ Parallel   │ SoA      │ Col-Major │ Part-Point   │ Expected    │
├─────────┼────────────┼──────────┼───────────┼──────────────┼─────────────┤
│ Full    │ Rayon ✅   │ Yes ✅   │ Yes ✅    │ Yes ✅       │ 6.66x       │
│ -Para   │ Serial     │ Yes      │ Yes       │ Yes          │ 1.5-2.0x    │
│ -SoA    │ Rayon      │ No (AoS) │ Yes       │ Yes          │ 5.5x?       │
│ -ColMaj │ Rayon      │ Yes      │ No        │ Yes          │ 6.0x?       │
│ -PartPt │ Rayon      │ Yes      │ Yes       │ No           │ 6.5x?       │
│ Base    │ Serial     │ No (AoS) │ No        │ No           │ 1.0x        │
└─────────┴────────────┴──────────┴───────────┴──────────────┴─────────────┘
```

**Run sequence**:
1. Full implementation (baseline: 6.66x) ✅ Already have this
2. Disable parallelization → measure serial speed (1.5-2x)
3. Disable SoA layout → measure AoS speed (5.5x?)
4. Disable column-major → measure row-major speed (6.0x?)
5. Disable partition_point → measure binary_search speed (6.5x?)

**Analysis**:
- If Full = 6.66x and Serial = 1.5x → **Parallelization = 4.4x**
- If Full = 6.66x and -SoA = 5.5x → **SoA = 1.2x**
- If Full = 6.66x and -ColMaj = 6.0x → **Column-Major = 1.11x**
- If Full = 6.66x and -PartPt = 6.5x → **partition_point = 1.02x**

---

## Implementation Strategy

### Phase 1: Add Feature Flags to Cargo.toml
```toml
[features]
default = ["use_rayon", "use_soa_layout", "use_column_major_layout", "use_partition_point"]
use_rayon = []
use_soa_layout = []
use_column_major_layout = []
use_partition_point = []
```

### Phase 2: Modify src/engine.rs
```rust
// Top of file, add:
#[cfg(feature = "use_rayon")]
use rayon::prelude::*;

// In execute_queries function:
let results: Vec<Vec<u32>> =
    #[cfg(feature = "use_rayon")]
    typed_queries.par_iter()

    #[cfg(not(feature = "use_rayon"))]
    typed_queries.iter()

    .map(|q| { ... })
    .collect();
```

### Phase 3: Modify src/index.rs
```rust
// For column-major vs row-major:
#[cfg(feature = "use_column_major_layout")]
for b in 0..n_bins {
    for h in 0..n_hists {
        val_vec.push(p[[h, b]]);
        idx_vec.push(ids[[h, b]]);
    }
}

#[cfg(not(feature = "use_column_major_layout"))]
for h in 0..n_hists {
    for b in 0..n_bins {
        val_vec.push(p[[h, b]]);
        idx_vec.push(ids[[h, b]]);
    }
}
```

### Phase 4: Benchmarking Script
Create `scripts/ablation_study.sh`:
```bash
#!/bin/bash

export OPENBLAS_NUM_THREADS=64

DATASET=/local-data/abumukh/data/gittables/eval_medium

echo "=== ABLATION STUDY - eval_medium ==="
echo ""

# 1. Full implementation
echo "Config: FULL (all optimizations)"
cargo build --release --features use_rayon,use_soa_layout,use_column_major_layout,use_partition_point
run-queries -i $DATASET/indices/best_config_rebinning.zst ... # time it

# 2. Serial version
echo "Config: -PARALLEL (serial only)"
cargo build --release --features use_soa_layout,use_column_major_layout,use_partition_point
run-queries ... # time it

# 3. Row-major layout
echo "Config: -COLMAJOR"
cargo build --release --features use_rayon,use_soa_layout,use_partition_point
run-queries ... # time it

# ... etc
```

---

## Expected Outcomes

**Thesis Narrative**:

> "Our optimization achieves 6.66x speedup through four complementary techniques:
>
> 1. **Language (Rust)**: Eliminates Python GIL → 2-3x ✓
> 2. **Parallelization (Rayon)**: Multi-core scaling → 4-5x ✓
> 3. **Memory Layout (SoA)**: Cache efficiency → 1.2x ✓
> 4. **Access Pattern (Column-major)**: Prefetching → 1.1x ✓
>
> Together: 2.5 × 4.5 × 1.2 × 1.05 ≈ 14x theoretical max,
> but limited by memory bandwidth to observed 6.66x on production data."

**Publication-Quality Result**:
- Shows you understand the system deeply
- Justifies each optimization decision
- Provides evidence for design trade-offs
- More valuable than "6.66x speedup" alone

---

## Why This Matters for Your Thesis

**Without ablation**: "We got 6.66x speedup using Rust and parallelization"
- Generic claim, hard to evaluate contribution

**With ablation**: "Parallelization contributes ~4.4x, SoA layout ~1.2x, ..."
- Shows understanding of system architecture
- Justifies why each technique was chosen
- Reveals memory bandwidth is the bottleneck (why speedup plateaus)
- Provides actionable insights for future optimization

---

## Implementation Roadmap

### Weekend Work (2-3 hours)
1. Add Cargo feature flags (~30 min)
2. Implement feature-gated code in engine.rs (~30 min)
3. Implement feature-gated code in index.rs (~30 min)
4. Create ablation_study.sh script (~30 min)

### Run Benchmarks (~2-3 hours)
1. Full config: 6.66x (already have)
2. -Parallel config: ~20 min benchmark
3. -SoA config: ~20 min benchmark
4. -ColMajor config: ~20 min benchmark
5. -PartPoint config: ~20 min benchmark

### Analysis & Documentation (~1 hour)
1. Compute contribution of each axis
2. Create visualization (contribution chart)
3. Write up findings in thesis
4. Create final ablation report

---

## Quick Decision Matrix

```
Should we do 50GB benchmark?     NO  (already have 3 datapoints)
Should we do ablation study?     YES (more valuable for thesis)
Effort: ~6 hours total
Value: High - shows system understanding
Result: Publication-quality evidence
```

---

## Next Steps

**Choose one**:

**Option A: Full Ablation (Recommended)**
- Implement all 5 feature flags
- Run systematic benchmarks
- Document findings
- ~5-6 hours total
- Result: Thesis-ready + publication-quality

**Option B: Minimal Ablation (Quick)**
- Implement just parallelization flag
- Show serial vs parallel speedup
- ~2 hours total
- Result: Shows Rayon is doing heavy lifting

**Option C: Focus on Specific Technique**
- If one technique is unclear, ablate just that
- E.g., "Is SoA really helping?" - test AoS
- ~1-2 hours per technique

Which appeals to you?
