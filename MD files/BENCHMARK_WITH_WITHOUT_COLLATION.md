# Two Approaches: WITH vs WITHOUT Collation

## APPROACH 1: FAST (No Collation) - 30 minutes total
Best for: **Speed benchmarking** (Python vs Rust comparison)

```bash
# Kill the long-running collation
pkill -9 -f collate_benchmark

# Setup
export OPENBLAS_NUM_THREADS=64
cd /home/abumukh-ldap/fainder-redone
DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"

# Step 1: Create index (15-20 min)
echo "Creating index..."
mkdir -p "$DATA_DIR/indices"

create-index \
  -i "$DATA_DIR/clustering.zst" \
  -m rebinning \
  -p float32 \
  -o "$DATA_DIR/indices" \
  --index-file best_config_rebinning.zst

echo "✓ Index created!"

# Step 2: Python baseline benchmark (2-5 min)
echo ""
echo "========================================"
echo "PYTHON BASELINE"
echo "========================================"
python_start=$(date +%s.%N)

FAINDER_NO_RUST=1 run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

python_end=$(date +%s.%N)
python_time=$(echo "$python_end - $python_start" | bc)

# Step 3: Rust optimized benchmark (<1 min)
echo ""
echo "========================================"
echo "RUST OPTIMIZED"
echo "========================================"
rust_start=$(date +%s.%N)

run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

rust_end=$(date +%s.%N)
rust_time=$(echo "$rust_end - $rust_start" | bc)

# Step 4: Results
echo ""
echo "========================================"
echo "RESULTS"
echo "========================================"
echo "Python: ${python_time}s"
echo "Rust: ${rust_time}s"
speedup=$(echo "scale=2; $python_time / $rust_time" | bc)
echo "SPEEDUP: ${speedup}x"
echo "========================================"
```

**Total time: ~30 minutes**
**Output: Speed comparison only**

---

## APPROACH 2: COMPLETE (With Collation) - 3+ hours total
Best for: **Full validation** (accuracy + speed)

```bash
# Start fresh (or resume if interrupted)
export OPENBLAS_NUM_THREADS=64
cd /home/abumukh-ldap/fainder-redone
DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"

# Step 1: Collate queries with ground truth (90-120 min)
echo "Collating queries with ground truth..."
echo "(This takes 90-120 minutes for large datasets)"

python3 experiments/collate_benchmark_queries.py \
  -d eval_10gb \
  -q "$DATA_DIR/queries/all.zst" \
  -c "$DATA_DIR/clustering.zst" \
  -w 64

echo "✓ Collation complete!"

# Step 2: Create index (15-20 min)
echo ""
echo "Creating index..."
mkdir -p "$DATA_DIR/indices"

create-index \
  -i "$DATA_DIR/clustering.zst" \
  -m rebinning \
  -p float32 \
  -o "$DATA_DIR/indices" \
  --index-file best_config_rebinning.zst

echo "✓ Index created!"

# Step 3: Python baseline benchmark (2-5 min)
echo ""
echo "========================================"
echo "PYTHON BASELINE"
echo "========================================"
python_start=$(date +%s.%N)

FAINDER_NO_RUST=1 run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

python_end=$(date +%s.%N)
python_time=$(echo "$python_end - $python_start" | bc)

# Step 4: Rust optimized benchmark (<1 min)
echo ""
echo "========================================"
echo "RUST OPTIMIZED"
echo "========================================"
rust_start=$(date +%s.%N)

run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

rust_end=$(date +%s.%N)
rust_time=$(echo "$rust_end - $rust_start" | bc)

# Step 5: Results with validation info
echo ""
echo "========================================"
echo "RESULTS"
echo "========================================"
echo "Collation status: ✓ Complete"
if [ -d "$DATA_DIR/results" ]; then
  echo "Validation queries: $(ls $DATA_DIR/results/*.zst 2>/dev/null | wc -l) files created"
fi
echo ""
echo "Python: ${python_time}s"
echo "Rust: ${rust_time}s"
speedup=$(echo "scale=2; $python_time / $rust_time" | bc)
echo "SPEEDUP: ${speedup}x"
echo "========================================"
```

**Total time: ~3+ hours**
**Output: Speed comparison + accuracy validation data**

---

## Side-by-Side Comparison

| Aspect | WITHOUT Collation | WITH Collation |
|--------|------------------|----------------|
| **Time** | ~30 min | ~3+ hours |
| **Index creation** | ✅ 15-20 min | ✅ 15-20 min |
| **Python benchmark** | ✅ 2-5 min | ✅ 2-5 min |
| **Rust benchmark** | ✅ <1 min | ✅ <1 min |
| **Collation** | ❌ Skipped | ✅ 90-120 min |
| **Accuracy validation** | ❌ Not available | ✅ Available |
| **Speed comparison** | ✅ YES | ✅ YES |
| **Best for** | Speed proof | Full validation |

---

## Quick Commands (Copy-Paste)

### FAST - Skip collation, get speedup in 30 min:
```bash
pkill -9 -f collate_benchmark
cd /home/abumukh-ldap/fainder-redone
export OPENBLAS_NUM_THREADS=64
DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"
mkdir -p "$DATA_DIR/indices"
create-index -i "$DATA_DIR/clustering.zst" -m rebinning -p float32 -o "$DATA_DIR/indices" --index-file best_config_rebinning.zst
time FAINDER_NO_RUST=1 run-queries -i "$DATA_DIR/indices/best_config_rebinning.zst" -t index -q "$DATA_DIR/queries/all.zst" -m recall --workers 4
time run-queries -i "$DATA_DIR/indices/best_config_rebinning.zst" -t index -q "$DATA_DIR/queries/all.zst" -m recall --workers 4
```

### COMPLETE - Full validation with collation:
```bash
cd /home/abumukh-ldap/fainder-redone
export OPENBLAS_NUM_THREADS=64
DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"
python3 experiments/collate_benchmark_queries.py -d eval_10gb -q "$DATA_DIR/queries/all.zst" -c "$DATA_DIR/clustering.zst" -w 64
mkdir -p "$DATA_DIR/indices"
create-index -i "$DATA_DIR/clustering.zst" -m rebinning -p float32 -o "$DATA_DIR/indices" --index-file best_config_rebinning.zst
time FAINDER_NO_RUST=1 run-queries -i "$DATA_DIR/indices/best_config_rebinning.zst" -t index -q "$DATA_DIR/queries/all.zst" -m recall --workers 4
time run-queries -i "$DATA_DIR/indices/best_config_rebinning.zst" -t index -q "$DATA_DIR/queries/all.zst" -m recall --workers 4
```

---

## Recommendation

**Use APPROACH 1 (Fast, 30 min)** because:
- ✅ You already have dev_small benchmarks (20x speedup proof)
- ✅ eval_medium is running overnight with full validation
- ✅ eval_10gb can be fast validation on medium dataset size
- ✅ Get results in 30 min instead of 3+ hours
- ✅ Shows scaling across different dataset sizes

**Which one do you want to run?**
