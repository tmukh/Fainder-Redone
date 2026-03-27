# FAINDER OPTIMIZATION TESTING & VALIDATION ACTION PLAN

**Status**: Ready to execute data preprocessing and benchmarking
**Current State**:
- ✅ CLI tools installed
- ✅ Rust engine built
- ✅ 56GB input data available
- ✅ 79GB free disk space
- ⏳ Processing data (next step)

---

## What You Have Right Now

### ✅ Optimizations Already Implemented
1. **Rust-based query engine** (src/engine.rs)
2. **SoA memory layout** (src/index.rs)
3. **Rayon parallelization** (active in code)
4. **partition_point search** (optimized binary search)
5. **18x speedup achieved** (verified in commit 4812cc4)

### ✅ Documentation Created (Phase 1)
- `OPTIMIZATION_ROADMAP.md` - 4-phase implementation plan
- `ABLATION_STUDY.md` - Ablation methodology
- `THESIS_MAPPING.md` - Thesis contributions mapping
- `DATA_SETUP_GUIDE.md` - Data preprocessing guide
- `scripts/check_setup_status.sh` - Quick status checker

### ✅ Benchmarking Infrastructure Ready
- `BENCHMARK_GUIDE.md` - How to run benchmarks
- `experiments/setup_gittables_minimal.sh` - Automated setup
- CLI tools: compute-histograms, cluster-histograms, create-index, run-queries

### ⏳ What's Missing (To Be Generated)
- Processed histogram data (.zst files)
- Indexes (best_config_rebinning.zst)
- Benchmark query sets
- Profiling data (perf, cache statistics)
- Ablation study results

---

## THE ROADMAP: From Here to Thesis-Ready

### PHASE A: Validate Existing 18x Speedup (Today, 2-3 hours)

**Goal**: Prove the optimizations work

**Steps**:
```bash
cd /home/abumukh-ldap/fainder-redone

# Step 1: Prepare small dataset
bash experiments/setup_gittables_minimal.sh dev_small

# Step 2: Test Python baseline (SLOW)
time FAINDER_NO_RUST=1 run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index \
  -q data/dev_small/queries/all.zst \
  -m recall \
  --workers 4

# Step 3: Test Rust optimized (FAST)
time run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index \
  -q data/dev_small/queries/all.zst \
  -m recall \
  --workers 4

# Step 4: Check speedup
# Compare timings: Rust should be ~10-20x faster
```

**Expected Output**:
```
Python baseline:  1.2 seconds
Rust optimized:   0.06 seconds
SPEEDUP:          20x ✓
```

**Deliverables**:
- ✅ Proof that optimizations work
- ✅ Baseline data for future comparisons

---

### PHASE B: Profiling & Performance Metrics (Phase 2, 1-2 hours)

**Goal**: Collect empirical evidence of cache efficiency

**Steps**:
```bash
# Step 1: Install profiling tools
sudo apt-get install -y linux-tools-generic
cargo install flamegraph

# Step 2: Profile Rust execution
perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses \
  run-queries \
    -i data/dev_small/indices/best_config_rebinning.zst \
    -t index \
    -q data/dev_small/queries/all.zst \
    -m recall \
    --workers 8

# Step 3: Generate flamegraph (optional, shows where time is spent)
cargo flamegraph --bin run-queries -- \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index \
  -q data/dev_small/queries/all.zst \
  -m recall
```

**Expected Metrics**:
- Instructions per Cycle (IPC): 2.5-3.5 (good)
- Cache Miss Rate: 2-5% (excellent)
- Branch Miss Rate: <2% (excellent)

**Deliverables**:
- `PROFILING_REPORT.md` showing cache efficiency
- Performance metrics validating SoA layout benefits
- Flamegraph showing hot paths

---

### PHASE C: Ablation Study (Phase 3, 8-10 hours)

**Goal**: Quantify each optimization's contribution

**Steps** (for future implementation):
1. Add feature flags to Cargo.toml
2. Create AoS variant for comparison
3. Create serial execution variant
4. Build each configuration
5. Run benchmark suite
6. Analyze and document results

**Deliverables**:
- `logs/ablation_study/results.csv` with all configurations
- Ablation analysis notebook
- Per-optimization contribution chart

---

## IMMEDIATE ACTION: Choose Your Path

### Path 1: QUICK VALIDATION (2-3 hours) ⭐ Recommended First Step

```bash
# Just validate existing speedup
bash experiments/setup_gittables_minimal.sh dev_small
time FAINDER_NO_RUST=1 run-queries -i data/dev_small/indices/best_config_rebinning.zst -t index -q data/dev_small/queries/all.zst -m recall --workers 4
time run-queries -i data/dev_small/indices/best_config_rebinning.zst -t index -q data/dev_small/queries/all.zst -m recall --workers 4
```

**Outcome**: Confirm 20x speedup exists, ready for profiling

---

### Path 2: COMPREHENSIVE EVALUATION (24-32 hours total)

**Step-by-step timeline**:

1. **Today (2-3 hours)**: Run dev_small setup + validation
2. **Tonight (20-24 hours)**: Run eval_medium setup + benchmarks (run in background)
3. **Tomorrow (2-4 hours)**: Profiling + analysis

```bash
# Run overnight in background
nohup bash experiments/setup_gittables_minimal.sh eval_medium > setup.log 2>&1 &
tail -f setup.log

# Check progress
du -sh data/eval_medium/
df -h
```

---

## Step-by-Step: Run Now

### ✅ Step 1: Quick Status Check (1 min)
```bash
cd /home/abumukh-ldap/fainder-redone
bash scripts/check_setup_status.sh
```

### ✅ Step 2: Start Data Preprocessing (2-3 hours)
```bash
bash experiments/setup_gittables_minimal.sh dev_small
```

This will:
1. Compute histograms from parquet (30-60 min)
2. Cluster histograms (20 min)
3. Generate queries (1 min)
4. Build Fainder index (5 min)

**Total time: ~2-3 hours**

### ✅ Step 3: Run Quick Benchmark (5 min)
Once setup completes:
```bash
# Baseline (slow)
time FAINDER_NO_RUST=1 run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index -q data/dev_small/queries/all.zst -m recall --workers 4

# Optimized (fast)
time run-queries \
  -i data/dev_small/indices/best_config_rebinning.zst \
  -t index -q data/dev_small/queries/all.zst -m recall --workers 4
```

### ✅ Step 4: Collect Profiling Data (15 min)
```bash
perf stat -e cycles,instructions,cache-references,cache-misses,branch-misses \
  run-queries \
    -i data/dev_small/indices/best_config_rebinning.zst \
    -t index -q data/dev_small/queries/all.zst \
    -m recall --workers $(nproc)
```

---

## Expected Outputs

### After Phase A (Quick Validation)
✅ Proof of 18x speedup
✅ Baseline benchmark data
✅ Ready for profiling

### After Phase B (Profiling)
✅ Cache efficiency metrics
✅ Branch prediction data
✅ IPC (Instructions per Cycle) analysis

### After Phase C (Ablation)
✅ Per-optimization contribution
✅ Memory layout impact (SoA vs AoS)
✅ Parallelization scaling curve

---

## Monitoring Long-Running Setup

If running eval_medium or larger overnight:

```bash
# In a separate terminal, monitor progress
watch -n 5 'du -sh data/eval_medium && echo "---" && ls -lh data/eval_medium/*.zst 2>/dev/null'

# Or check logs
tail -f FAINDER_*.log

# Or check disk I/O
iostat -m 1
```

---

## Success Criteria

### Phase A (Quick Validation) - PASS if:
- ✅ dev_small setup completes without errors
- ✅ Python baseline completes (even if slow)
- ✅ Rust version completes (fast, <1 second)
- ✅ Speedup is >10x

### Phase B (Profiling) - PASS if:
- ✅ Cache miss rate <5%
- ✅ IPC between 2-3.5
- ✅ Branch miss rate <2%

### Phase C (Ablation) - PASS if:
- ✅ All variants built successfully
- ✅ CSV results file generated
- ✅ Ablation shows each optimization contributes positively

---

## Estimated Timeline Summary

| Phase | Setup | Test | Analysis | Total |
|-------|-------|------|----------|-------|
| A (Validation) | 2-3h | 0.5h | 0.5h | **3-4h** |
| B (Profiling) | (reuse) | 0.5h | 1h | **1.5h** |
| C (Ablation) | 20-25h | 5h | 2h | **27-32h** |
| **TOTAL** | | | | **32-38h** |

---

## Files Ready to Execute

- ✅ `experiments/setup_gittables_minimal.sh` - Data prep
- ✅ `scripts/check_setup_status.sh` - Status check
- ✅ `BENCHMARK_GUIDE.md` - Benchmark commands
- ✅ `DATA_SETUP_GUIDE.md` - Detailed preprocessing guide
- ✅ `OPTIMIZATION_ROADMAP.md` - Full roadmap
- ✅ `ABLATION_STUDY.md` - Ablation methodology

---

## Next Actions

**DO THIS NOW** (5 minutes):
```bash
cd /home/abumukh-ldap/fainder-redone
bash scripts/check_setup_status.sh
```

**DO THIS NEXT** (2-3 hours):
```bash
bash experiments/setup_gittables_minimal.sh dev_small
```

**After setup completes** (15 minutes):
```bash
# Test both versions and compare timings
time FAINDER_NO_RUST=1 run-queries -i data/dev_small/indices/best_config_rebinning.zst -t index -q data/dev_small/queries/all.zst -m recall --workers 4
time run-queries -i data/dev_small/indices/best_config_rebinning.zst -t index -q data/dev_small/queries/all.zst -m recall --workers 4
```

---

## Questions / Debugging

**Q: How do I know if setup is still running?**
```bash
ps aux | grep compute-histograms
ls -lh data/dev_small/  # Check if files are growing
```

**Q: How much disk space will I need?**
- dev_small: ~500MB
- eval_small: ~2GB
- eval_medium: ~10GB
- You have 79GB available → All options work!

**Q: Can I run this on my laptop?**
- Yes! Start with dev_small (2-3 hours)
- eval_small is also laptop-friendly (4-6 hours)
- eval_medium prefers 8+ core workstation (20-30 hours)

**Q: What if I run out of disk space?**
```bash
df -h /home/abumukh-ldap/fainder-redone
rm -rf data/dev_small  # Clean up to save space
```

---

## Success Checkpoint

After completing Phase A (Quick Validation), you will have:

✅ Proven the 18x speedup exists in your environment
✅ Generated Phase 1 documentation (already done)
✅ Ready to move to Phase 2 (Profiling)
✅ Thesis-ready validation data

This is your proof-of-concept before investing in full ablation study.
