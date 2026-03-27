# Data Setup & Benchmark Preparation Guide

This guide walks you through setting up the GitTables data for the Fainder optimization benchmarks.

## Overview: Data Processing Pipeline

```
Raw Parquet Files (56GB)
    ↓
[compute-histograms] → histograms.zst (1-3GB depending on sample size)
    ↓
[compute-distributions] → normal_dists.zst (ground truth)
    ↓
[cluster-histograms] → clustering.zst (index configuration)
    ↓
[generate-queries] → all.zst (benchmark queries)
    ↓
[collate_benchmark_queries.py] → Attach ground truth to queries
    ↓
[create-index] → Fainder index (best_config_rebinning.zst)
    ↓
READY FOR BENCHMARKING!
```

## Prerequisites

### Check if CLI tools are installed

```bash
# Test if CLI tools are available
which compute-histograms
which cluster-histograms
which create-index
which run-queries
```

If any are missing, install with:
```bash
pip install -e ".[dev]"  # or pip install -e .
maturin develop --release  # Build Rust extension
```

### Data Location

Your input data:
```
/local-data/abumukh/data/gittables/pq/  (56GB of parquet files)
```

Output will be created in:
```
/home/abumukh-ldap/fainder-redone/data/dev_small/      (~100MB)
/home/abumukh-ldap/fainder-redone/data/eval_small/     (~500MB)
/home/abumukh-ldap/fainder-redone/data/eval_medium/    (~2GB)
/home/abumukh-ldap/fainder-redone/data/eval_large/     (~50GB)  [production]
```

---

## Setup Options

### Option 1: Quick Dev Setup (2-3 hours)

**Best for**: Testing code changes, quick validation

```bash
bash experiments/setup_gittables_minimal.sh dev_small
```

**Output**:
- ~1000 histograms (1% sample of full dataset)
- ~100 queries
- Index size: ~100MB
- Suitable for laptop/small workstations

**Time Estimates**:
- Histogram computation: 30-60 min
- Clustering: ~20 min
- Index creation: ~5 min
- **Total: ~2-3 hours**

### Option 2: Small Eval Setup (4-6 hours)

**Best for**: Quick optimization evaluation

```bash
bash experiments/setup_gittables_minimal.sh eval_small
```

**Output**:
- ~50,000 histograms (5% sample)
- ~1000 queries
- Index size: ~500MB
- Suitable for medium workstations

**Time Estimates**:
- Histogram computation: 1-2 hours
- Clustering: ~30 min
- Index creation: ~10 min
- **Total: ~4-6 hours**

### Option 3: Medium Eval Setup (20-30 hours)

**Best for**: Serious benchmarking, academic papers

```bash
bash experiments/setup_gittables_minimal.sh eval_medium
```

**Output**:
- ~200,000 histograms (20% sample)
- ~5000 queries
- Index size: ~2GB
- Suitable for high-end workstations (16+ cores)

**Time Estimates**:
- Histogram computation: 10-16 hours
- Clustering: ~2 hours
- Index creation: ~1 hour
- **Total: ~20-30 hours**

### Option 4: Full Production Setup (48-72 hours)

**Best for**: Full VLDB reproduction

```bash
bash experiments/setup.sh  # Or modify for 100% of GitTables
```

**Output**:
- ~1M+ histograms (full dataset)
- ~50K queries
- Index size: ~50GB
- Requires: 500GB free space, high-end cluster

---

## How to Run the Setup

### Step 1: Choose Your Configuration

```bash
# Quick test (recommended to start)
time bash experiments/setup_gittables_minimal.sh dev_small

# Or for Slack/background:
nohup bash experiments/setup_gittables_minimal.sh eval_small > setup.log 2>&1 &
tail -f setup.log
```

### Step 2: Monitor Progress

Each CLI command logs to stdout. For long-running processes:

```bash
# In another terminal
tail -f FAINDER_*.log
df -h  # Check disk space
top -p $(pgrep -f "compute-histograms") # Monitor CPU
```

### Step 3: Verify Output

After setup completes:

```bash
# Check output directory
ls -lh data/dev_small/
# Should contain:
#   histograms.zst (~50MB for dev_small)
#   clustering.zst (~10MB)
#   queries/all.zst (~1MB)
#   indices/best_config_rebinning.zst (~50MB)
```

---

## Quick Benchmarking After Setup

Once setup completes, run quick benchmarks:

### Benchmark 1: Verify 18x Speedup

```bash
# Python baseline (slow)
time FAINDER_NO_RUST=1 run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index \
  -q data/dev_small/queries/all.zst \
  -m recall \
  --workers 4

# Rust optimized (fast)
time run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index \
  -q data/dev_small/queries/all.zst \
  -m recall \
  --workers 4
```

**Expected for dev_small**:
- Python: ~1-2 seconds
- Rust: ~0.1 seconds
- **Speedup: ~10-20x** (9-core system reference: 18x on 8 cores)

### Benchmark 2: Runtime Analysis

```bash
# Generate profiling data
perf stat -e cycles,instructions,cache-references,cache-misses \
  run-queries \
    -i data/dev_small/indices/best_config_rebinning.zst \
    -t index \
    -q data/dev_small/queries/all.zst \
    -m recall \
    --workers $(nproc)
```

**Output interpretation**:
- `cycles`: CPU cycles used
- `instructions`: Operations performed
- `cache-references`: Total cache accesses
- `cache-misses`: Failed cache lookups
- **Good system**: <5% cache miss rate

---

## Estimated Timeline for Full Testing

| Phase | Setup | Benchmark | Analysis | Total |
|-------|-------|-----------|----------|-------|
| **Phase 1** (quick test) | 2-3h | 0.5h | 1h | **3.5-4.5h** |
| **Phase 2** (small eval) | 4-6h | 2h | 2h | **8-10h** |
| **Phase 3** (medium eval) | 20-30h | 8h | 4h | **32-42h** |
| **Production** (full) | 48-72h | 24h | 12h | **84-108h** |

---

## Troubleshooting

### Error: "compute-histograms not found"

Solution: Ensure CLI is installed
```bash
pip install -e .
maturin develop --release
which compute-histograms
```

### Error: "Input directory does not exist"

Solution: Verify parquet file location
```bash
ls /local-data/abumukh/data/gittables/pq/ | head
# Should see: abstraction_tables_licensed_*.pq
```

### Error: "Out of disk space"

Solution: Check available space
```bash
df -h /home/abumukh-ldap/fainder-redone/
# Need at least 10GB free for dev_small
# Need at least 100GB free for eval_medium
```

### Process killed/timeout

Solution: Run with nohup in background
```bash
nohup bash experiments/setup_gittables_minimal.sh eval_small > setup.log 2>&1 &
```

### Slow performance

Solution: Check available cores
```bash
nproc  # Should see: 8-16+
top    # Check if CPU-intensive processes are running
```

---

## What Each Step Does

### 1. compute-histograms
Converts parquet table files into distribution histograms with N bins.

**Input**: Parquet files from GitTables (56GB)
**Output**: Compressed histogram collection (histograms.zst)
**Time**: 30 min (dev_small) to 16 hours (eval_medium)
**Key Parameter**: `-f 0.01` (sample fraction, 1% = dev_small)

### 2. compute-distributions
Creates ground truth distributions for accuracy evaluation.

**Input**: Same parquet files
**Output**: Normal distribution parameters (normal_dists.zst)
**Time**: 10-20 min
**Purpose**: Enables accuracy comparison against true distributions

### 3. cluster-histograms
Clusters histograms into K groups for efficient index creation.

**Input**: Histograms.zst
**Output**: Clustering configuration (clustering.zst)
**Time**: 20 min (K=10) to 2 hours (K=100)
**Key Parameter**: `-c K K` (number of clusters, adaptive)

### 4. generate-queries
Creates random benchmark queries at various percentiles.

**Input**: None (generates synthetically)
**Output**: Query collection (all.zst)
**Time**: <1 minute
**Parameters**:
- `--n-percentiles`: Number of percentile thresholds (10-50)
- `--n-reference-values`: Samples per percentile (10-100)

### 5. collate_benchmark_queries.py
Attaches ground truth answers to each query.

**Input**: Queries + Clustering + Ground truth distributions
**Output**: Augmented query file with expected results
**Time**: 10-30 min (parallelized)
**Purpose**: Enables accuracy verification

### 6. create-index
Builds the Fainder index structure.

**Input**: Clustering configuration file
**Output**: Index file (best_config_rebinning.zst)
**Time**: 5 min (dev_small) to 1 hour (eval_medium)
**Modes**: `rebinning` (fast, baseline) vs `conversion` (slower, more accurate)

---

## Next Steps

### After Setup Completes

1. **Run Benchmarks**: Follow "Quick Benchmarking" section above
2. **Measure Profiling**: Collect cache and performance metrics
3. **Validate Speedup**: Confirm 18x speedup claim
4. **Run Ablation**: Test individual optimizations (Phase 3)

### For Complete Evaluation

1. Complete Phase 2 (Profiling setup)
2. Complete Phase 3 (Ablation study with feature flags)
3. Generate analysis notebook with results

---

## File References

- Setup script: `experiments/setup_gittables_minimal.sh`
- Benchmark guide: `BENCHMARK_GUIDE.md`
- Optimization roadmap: `OPTIMIZATION_ROADMAP.md`
- Ablation methodology: `ABLATION_STUDY.md`

---

## Questions?

- **Disk space**: Check `df -h /home/abumukh-ldap/fainder-redone/`
- **Memory usage**: Use `htop` or `free -h`
- **CPU cores**: Check `nproc`
- **Time estimates**: Based on 8-core, 64GB RAM system
