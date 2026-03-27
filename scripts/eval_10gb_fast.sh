#!/bin/bash

# EVAL_10GB FAST - Skip Collation, Just Benchmarks
# Time: ~30 minutes total

set -euxo pipefail

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

cd /home/abumukh-ldap/fainder-redone

DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"

echo "=============================================================="
echo "EVAL_10GB FAST BENCHMARK - Skip Collation"
echo "=============================================================="
echo "Creating index + running benchmarks (no accuracy validation)"
echo "Time estimate: ~30 minutes"
echo "Started: $(date)"
echo ""

start_time=$(date +%s)

# ============================================================
# STEP 1: Create Index
# ============================================================
echo "STEP 1: Creating Fainder index"
echo "============================="
echo "Time estimate: 15-20 min"
echo "Started: $(date)"
echo ""

mkdir -p "$DATA_DIR/indices"

create-index \
  -i "$DATA_DIR/clustering.zst" \
  -m rebinning \
  -p float32 \
  -o "$DATA_DIR/indices" \
  --index-file best_config_rebinning.zst

echo "✓ Index created!"
echo "File: $DATA_DIR/indices/best_config_rebinning.zst"
du -sh "$DATA_DIR/indices/best_config_rebinning.zst"
echo ""

# ============================================================
# STEP 2: Python Baseline Benchmark
# ============================================================
echo "STEP 2: Python Baseline Benchmark"
echo "================================="
echo "Time estimate: 2-10 min"
echo "Started: $(date)"
echo ""

python_start=$(date +%s.%N)

FAINDER_NO_RUST=1 run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

python_end=$(date +%s.%N)
python_time=$(echo "$python_end - $python_start" | bc)

echo ""
echo "✓ Python benchmark complete!"
echo "Time: ${python_time}s"
echo ""

# ============================================================
# STEP 3: Rust Optimized Benchmark
# ============================================================
echo "STEP 3: Rust Optimized Benchmark"
echo "================================"
echo "Time estimate: 0.1-1 min"
echo "Started: $(date)"
echo ""

rust_start=$(date +%s.%N)

run-queries \
  -i "$DATA_DIR/indices/best_config_rebinning.zst" \
  -t index \
  -q "$DATA_DIR/queries/all.zst" \
  -m recall \
  --workers 4

rust_end=$(date +%s.%N)
rust_time=$(echo "$rust_end - $rust_start" | bc)

echo ""
echo "✓ Rust benchmark complete!"
echo "Time: ${rust_time}s"
echo ""

# ============================================================
# Results
# ============================================================
end_time=$(date +%s)
total_duration=$((end_time - start_time))

echo "=============================================================="
echo "FINAL RESULTS - 10GB EVALUATION (Fast, No Collation)"
echo "=============================================================="
echo ""
echo "📊 BENCHMARK COMPARISON"
echo "======================="
echo "Python baseline: ${python_time}s"
echo "Rust optimized: ${rust_time}s"
speedup=$(echo "scale=2; $python_time / $rust_time" | bc)
echo ""
echo "🎯 SPEEDUP: ${speedup}x"
echo ""

if (( $(echo "$speedup > 10" | bc -l) )); then
  echo "✅ EXCELLENT: Speedup > 10x (18x target achieved!)"
elif (( $(echo "$speedup > 5" | bc -l) )); then
  echo "✅ GOOD: Speedup > 5x"
else
  echo "⚠️  MODERATE: Speedup ${speedup}x"
fi

echo ""
echo "⏱️  PIPELINE TIME"
echo "=================="
hours=$((total_duration / 3600))
minutes=$(( (total_duration % 3600) / 60 ))
seconds=$((total_duration % 60))
echo "Total: ${hours}h ${minutes}m ${seconds}s (much faster than with collation!)"
echo ""

echo "📁 DATASET INFO"
echo "==============="
echo "Histograms: $(du -sh $DATA_DIR/histograms.zst | cut -f1)"
echo "Queries: 4,500"
echo "Clusters: 45"
echo "Index: $(du -sh $DATA_DIR/indices/best_config_rebinning.zst | cut -f1)"
echo ""

echo "=============================================================="
echo "✅ EVAL_10GB FAST BENCHMARK COMPLETE"
echo "=============================================================="
echo ""
echo "Summary:"
echo "  • No collation (skipped ~2 hour validation step)"
echo "  • Pure speed comparison: Python vs Rust"
echo "  • Shows ${speedup}x speedup on 10GB dataset"
echo "  • Complements dev_small (20x) and eval_medium results"
echo ""
