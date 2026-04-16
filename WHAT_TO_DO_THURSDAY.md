# What To Do Thursday — Ablation Experiments

## Research Question
Which optimization techniques (Rust/compiler, SoA memory layout, Rayon parallelism, algorithmic search) contribute most to Fainder's speedup, and *why* does this workload benefit from each one specifically?

---

## Current State of Experiments

### Done ✅
| Experiment | Dataset | Result |
|---|---|---|
| Baseline comparison (all methods) | dev_small | exact 56s, binsort 10.8s, Python-rebinning 0.83s, Rust-rebinning 0.70s |
| Speedup measurement | eval_medium | Python 4438s → Rust 666s = **6.66x** |
| Speedup measurement | eval_10gb | Python 514s → Rust 85s = **6.02x** |
| VLDB paper baselines | gittables/sportstables/open_data_usa | Python-only, all methods |

### Missing ❌ (what to run Thursday)
1. Baseline comparison on eval_medium and eval_10gb (exact/binsort/ndist/pscan/Fainder Python+Rust)
2. Parallelism ablation: thread count sweep 1→64 on dev_small and eval_medium
3. Accuracy confirmation: Fainder Rust vs Python produce identical results
4. dev_small conversion index needs to be built (only rebinning exists)

---

## Step 0: Rebuild Rust Extension (5 min)

There are uncommitted changes in `src/engine.rs`, `src/index.rs`, `fainder/execution/percentile_queries.py` that add `num_threads` parameter support. **Compile these first** or the ablation scripts won't work.

```bash
cd /home/abumukh-ldap/fainder-redone
source venv/bin/activate
maturin develop --release
```

Verify with:
```bash
python -c "from fainder import fainder_core; print('OK')"
```

---

## Step 1: Launch All Experiments in Tmux

Run this one-liner to create all 4 sessions at once:

```bash
cd /home/abumukh-ldap/fainder-redone && source venv/bin/activate

# Baseline comparisons (all methods on larger datasets)
tmux new-session -d -s baseline-medium  "cd /home/abumukh-ldap/fainder-redone && source venv/bin/activate && bash scripts/baseline_comparison.sh eval_medium 2>&1 | tee /tmp/baseline_medium.log"
tmux new-session -d -s baseline-10gb   "cd /home/abumukh-ldap/fainder-redone && source venv/bin/activate && bash scripts/baseline_comparison.sh eval_10gb  2>&1 | tee /tmp/baseline_10gb.log"

# Parallelism ablation: thread count sweep (1, 2, 4, 8, 16, 32, 64 threads)
tmux new-session -d -s ablation-small  "cd /home/abumukh-ldap/fainder-redone && source venv/bin/activate && bash scripts/ablation_parallel.sh dev_small  2>&1 | tee /tmp/ablation_small.log"
tmux new-session -d -s ablation-medium "cd /home/abumukh-ldap/fainder-redone && source venv/bin/activate && bash scripts/ablation_parallel.sh eval_medium 2>&1 | tee /tmp/ablation_medium.log"

echo "Sessions started. Attach with: tmux attach -t baseline-medium"
```

Or use the launcher script once created:
```bash
bash scripts/launch_tmux_experiments.sh
```

### Monitor Progress
```bash
tail -f /tmp/baseline_medium.log /tmp/baseline_10gb.log
tail -f /tmp/ablation_small.log /tmp/ablation_medium.log
```

### Expected Run Times
| Session | Time Estimate |
|---|---|
| baseline-medium | 3–5 hours |
| baseline-10gb | 2–4 hours |
| ablation-small | 30–60 min |
| ablation-medium | 4–8 hours |

---

## Step 2: Build dev_small Conversion Index (optional, fast ~5 min)

Needed for a full rebinning vs conversion comparison on dev_small:

```bash
# Check exact flags first
create-index --help

# Then create (adjust flags as needed):
create-index \
  -H /local-data/abumukh/data/gittables/dev_small/histograms.zst \
  -c /local-data/abumukh/data/gittables/dev_small/clustering.zst \
  -o /local-data/abumukh/data/gittables/dev_small/indices/best_config_conversion.zst \
  --mode conversion
```

---

## Step 3: Read Results When Done

### Ablation table (thread scaling)
```bash
grep "Raw index-based query execution time" logs/ablation/dev_small-rust-t*.log \
  | sed 's/.*t\([0-9]*\)\.log.*: \([0-9.]*\)s/threads=\1  time=\2s/'
```

### Baseline summary table
```bash
grep "Ran [0-9]* queries in" logs/baseline_comparison/eval_medium-*.log \
  | sed 's|.*eval_medium-\(.*\)\.log.*in \(.*\)s|\1\t\2s|'
```

---

## What to Implement Next (Deferred)

These require code changes and should be done in a new Claude session:

### A. SoA vs AoS Memory Layout Ablation
Add a Cargo feature flag that switches `SubIndex` from Structure-of-Arrays to Array-of-Structs:
- File: `src/index.rs` — modify `SubIndex` struct and flattening logic
- File: `src/engine.rs` — modify column access pattern
- Build two variants: `--features soa` (default) vs `--no-default-features` (AoS)
- Measure cache miss rates with `perf stat -e L1-dcache-load-misses,...`

### B. Cache Profiling
```bash
export OPENBLAS_NUM_THREADS=64
perf stat -e L1-dcache-load-misses,L1-dcache-loads,LLC-loads,LLC-load-misses \
  run-queries -i data/eval_medium/... -q ... -m recall
```

### C. Index Construction Time Table
Measure and compare index build time: rebinning vs conversion × dataset sizes.

---

## Thesis Scientific Narrative (Key Points)

After results come in, the thesis tells this story:

1. **Python overhead dominates at small scale** → 20x speedup for dev_small (50k hists)
2. **Memory bandwidth becomes the bottleneck at scale** → 6.66x at 200k, 6.02x at 323k
3. **Rayon scales near-linearly** because queries are embarrassingly parallel (no shared state)
4. **SoA benefits from Fainder's specific access pattern**: binary search over `values[]` is sequential — SoA puts all values contiguous in memory, AoS would stride over (value,index) pairs and pollute cache lines
5. **This explains why this workload is "Rayon-friendly"** but other DB workloads (joins, aggregations) would not scale as cleanly

The ablation table (threads=1 to threads=64) is the core scientific result. The baseline comparison table (exact/binsort/ndist/pscan/Fainder) provides the context of *how much better* the optimized version is.

---

## Available Indices Reference

| Dataset | Rebinning | Conversion |
|---|---|---|
| dev_small | `data/dev_small/indices/best_config_rebinning.zst` | ❌ need to build |
| eval_medium | `/local-data/abumukh/data/gittables/eval_medium/indices/best_config_rebinning.zst` | ✅ same dir |
| eval_10gb | `/local-data/abumukh/data/gittables/eval_10gb/indices/best_config_rebinning.zst` | ✅ same dir |

## Key Environment Variables
```bash
export OPENBLAS_NUM_THREADS=64   # Prevents overflow on 192-core system
export NUMEXPR_NUM_THREADS=64
FAINDER_NO_RUST=1                # Force Python execution (baseline)
FAINDER_NUM_THREADS=N            # Limit Rayon to N threads (ablation)
```
