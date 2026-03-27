# 10GB Evaluation Dataset - Complete Command Sequence

All commands in order for 10GB (~6.5% sample) dataset with benchmarks.

## Quick Start (Run Everything Automatically)

```bash
cd /home/abumukh-ldap/fainder-redone
bash scripts/eval_10gb_complete.sh
```

**Time estimate**: ~10-12 hours total

---

## Step-by-Step Commands (If Running Manually)

### Setup Environment
```bash
export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export OPENBLAS_CORETYPE=HASWELL

cd /home/abumukh-ldap/fainder-redone

DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"
INPUT_DIR="/local-data/abumukh/data/gittables/pq"
SAMPLE_FRACTION="0.065"

mkdir -p "$DATA_DIR"
mkdir -p data/eval_10gb
```

---

### STEP 1: Compute Histograms (5-10 min)
```bash
compute-histograms \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/histograms.zst" \
  -f 0.065 \
  --bin-range 10 20 \
  -w 192
```

**Expected output**: 65k-70k histograms in ~3-5 MB compressed

---

### STEP 2: Compute Distributions (15-20 min)
```bash
compute-distributions \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/normal_dists.zst" \
  -k normal \
  -w 192
```

**Expected output**: ~35-50 MB compressed

---

### STEP 3: Cluster Histograms (45-75 min)
```bash
cluster-histograms \
  -i "$DATA_DIR/histograms.zst" \
  -o "$DATA_DIR/clustering.zst" \
  -a kmeans \
  -c 80 80 \
  -b 40000 \
  -t quantile \
  --alpha 1 \
  --seed 42 \
  --log-level INFO
```

**Expected output**: ~3-5 MB

---

### STEP 4: Create Symlinks (1 min)
```bash
ln -sf "$DATA_DIR/histograms.zst" data/eval_10gb/histograms.zst
ln -sf "$DATA_DIR/clustering.zst" data/eval_10gb/clustering.zst
mkdir -p "$DATA_DIR/queries"
ln -sf "$DATA_DIR/queries" data/eval_10gb/queries
```

---

### STEP 5: Generate Queries (1 min)
```bash
generate-queries \
  -o "$DATA_DIR/queries/all.zst" \
  --n-percentiles 30 \
  --n-reference-values 75 \
  --seed 42 \
  --reference-value-range "-10000" "10000"
```

**Expected output**: 2,250 queries in ~5-10 MB

---

### STEP 6: Collate Queries (30-60 min)
```bash
python3 experiments/collate_benchmark_queries.py \
  -d eval_10gb \
  -q "$DATA_DIR/queries/all.zst" \
  -c "$DATA_DIR/clustering.zst" \
  -w 64
```

**Expected output**: Results with ground truth collated

---

### STEP 7: Create Index (15-30 min)
```bash
mkdir -p "$DATA_DIR/indices"

create-index \
  -i "$DATA_DIR/clustering.zst" \
  -m rebinning \
  -p float32 \
  -o "$DATA_DIR/indices" \
  --index-file best_config_rebinning.zst
```

**Expected output**: Index file ~500KB - 1MB

---

### STEP 8: Python Baseline Benchmark (2-10 min)
```bash
echo "START PYTHON: $(date)"
time FAINDER_NO_RUST=1 run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4
echo "END PYTHON: $(date)"
```

**Expected result**:
- Python: ~5-15 seconds (depending on query count and cluster size)
- Look for: "Ran X queries in Y seconds"

---

### STEP 9: Rust Optimized Benchmark (0.1-1 min)
```bash
echo "START RUST: $(date)"
time run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4
echo "END RUST: $(date)"
```

**Expected result**:
- Rust: ~0.2-1 second (10-25x faster than Python)
- Look for: "Ran X queries in Y seconds"

---

## Monitoring & Checking Progress

While pipeline runs:

```bash
# Watch the log in real-time
tail -f /tmp/eval_10gb_pipeline.log

# Check current step
ps aux | grep -E 'compute-histograms|cluster-histograms|create-index' | grep -v grep

# Check disk space
df -h /local-data/abumukh/data/gittables/

# Check data size so far
du -sh /local-data/abumukh/data/gittables/eval_10gb/
```

---

## Running in Background (Recommended for 10+ hours)

```bash
# Run the full pipeline in background
nohup bash /home/abumukh-ldap/fainder-redone/scripts/eval_10gb_complete.sh \
  > /tmp/eval_10gb_pipeline.log 2>&1 &

# Monitor progress
tail -f /tmp/eval_10gb_pipeline.log

# Check when done
tail -20 /tmp/eval_10gb_pipeline.log | grep -E 'SPEEDUP|COMPLETE'
```

---

## Expected Timeline Breakdown

| Step | Time | Cumulative |
|------|------|-----------|
| Histograms | 5-10m | 5-10m |
| Distributions | 15-20m | 20-30m |
| Clustering | 45-75m | 65-105m (~2h) |
| Queries | <1m | ~2h |
| Collation | 30-60m | 2.5-3h |
| Index | 15-30m | 3-3.5h |
| Python benchmark | 2-10m | 3-3.5h |
| Rust benchmark | 0.1-1m | 3-3.5h |
| **TOTAL** | | **10-12 hours** |

---

## Expected Results

### Data Size
- Histograms: ~3-5 MB
- Distributions: ~35-50 MB
- Clustering: ~3-5 MB
- Queries: ~5-10 MB
- Index: ~500KB - 1 MB
- **Total**: ~50-70 MB (compressed)
- Extracted: ~10GB (uncompressed)

### Benchmark Results
- Python baseline: ~5-15 seconds
- Rust optimized: ~0.2-1 second
- **Expected speedup: 15-25x** ✓

---

## Commands to Save Results

```bash
# Save benchmark results
RESULTS_FILE="/tmp/eval_10gb_results.txt"

echo "=== 10GB EVALUATION RESULTS ===" > $RESULTS_FILE
echo "Date: $(date)" >> $RESULTS_FILE
echo "" >> $RESULTS_FILE

# Run Python
echo "PYTHON BASELINE:" >> $RESULTS_FILE
time FAINDER_NO_RUST=1 run-queries \
  -i /local-data/abumukh/data/gittables/eval_10gb/indices/best_config_rebinning.zst \
  -t index \
  -q /local-data/abumukh/data/gittables/eval_10gb/queries/all.zst \
  -m recall \
  --workers 4 2>&1 | tee -a $RESULTS_FILE

# Run Rust
echo "RUST OPTIMIZED:" >> $RESULTS_FILE
time run-queries \
  -i /local-data/abumukh/data/gittables/eval_10gb/indices/best_config_rebinning.zst \
  -t index \
  -q /local-data/abumukh/data/gittables/eval_10gb/queries/all.zst \
  -m recall \
  --workers 4 2>&1 | tee -a $RESULTS_FILE

# View results
cat $RESULTS_FILE
```

---

## Cleanup (If Needed)

```bash
# Stop ongoing pipeline
pkill -f eval_10gb_complete

# Remove data (if disk space needed)
rm -rf /local-data/abumukh/data/gittables/eval_10gb/

# Remove symlinks
rm -rf /home/abumukh-ldap/fainder-redone/data/eval_10gb/
```

---

## Quick Copy-Paste (All-in-One)

```bash
cd /home/abumukh-ldap/fainder-redone && \
export OPENBLAS_NUM_THREADS=64 && \
export NUMEXPR_NUM_THREADS=64 && \
nohup bash scripts/eval_10gb_complete.sh > /tmp/eval_10gb_pipeline.log 2>&1 & && \
echo "Pipeline started in background!" && \
echo "Monitor with: tail -f /tmp/eval_10gb_pipeline.log"
```

---

## Success Indicators

Check for these lines in output:

```
✓ Histograms complete!
✓ Distributions complete!
✓ Clustering complete!
✓ Queries generated!
✓ Queries collated!
✓ Index created!
✓ Python benchmark complete!
✓ Rust benchmark complete!
🎯 SPEEDUP: XXx
✅ COMPLETE - 10GB EVALUATION PIPELINE FINISHED
```
