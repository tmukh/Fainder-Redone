#!/bin/bash

# EVAL_MEDIUM FAST - Complete pipeline skipping collation
# Time: ~1.5-2 hours total
# (Histograms already created, continue from distributions)

set -euxo pipefail

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export OPENBLAS_CORETYPE=HASWELL

cd /home/abumukh-ldap/fainder-redone

DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"

echo "=============================================================="
echo "EVAL_MEDIUM FAST BENCHMARK - Skip Collation"
echo "=============================================================="
echo "Creating: distributions → clustering → queries → index → benchmarks"
echo "Time estimate: ~1.5-2 hours (histograms already done)"
echo "Started: $(date)"
echo ""

start_time=$(date +%s)

# ============================================================
# STEP 1: Compute Distributions
# ============================================================
echo "STEP 1: Computing ground truth distributions"
echo "============================================"
echo "Time estimate: 20-40 min"
echo "Started: $(date)"
echo ""

compute-distributions \
  -i /local-data/abumukh/data/gittables/pq \
  -o "$DATA_DIR/normal_dists.zst" \
  -k normal \
  -w 192

echo "✓ Distributions complete!"
echo "File: $DATA_DIR/normal_dists.zst"
du -sh "$DATA_DIR/normal_dists.zst"
echo ""

# ============================================================
# STEP 2: Cluster Histograms
# ============================================================
echo "STEP 2: Clustering histograms (K=100)"
echo "====================================="
echo "Time estimate: 60-90 min"
echo "Started: $(date)"
echo ""

cluster-histograms \
  -i "$DATA_DIR/histograms.zst" \
  -o "$DATA_DIR/clustering.zst" \
  -a kmeans \
  -c 100 100 \
  -b 50000 \
  -t quantile \
  --alpha 1 \
  --seed 42 \
  --log-level INFO

echo "✓ Clustering complete!"
echo "File: $DATA_DIR/clustering.zst"
du -sh "$DATA_DIR/clustering.zst"
echo ""

# ============================================================
# STEP 3: Generate Queries
# ============================================================
echo "STEP 3: Generating benchmark queries"
echo "===================================="
echo "Time estimate: <1 min"
echo "Started: $(date)"
echo ""

mkdir -p "$DATA_DIR/queries"

generate-queries \
  -o "$DATA_DIR/queries/all.zst" \
  --n-percentiles 50 \
  --n-reference-values 100 \
  --seed 42 \
  --reference-value-range "-10000" "10000"

echo "✓ Queries generated!"
echo "File: $DATA_DIR/queries/all.zst"
du -sh "$DATA_DIR/queries/all.zst"
echo ""

# ============================================================
# STEP 4: Create Index
# ============================================================
echo "STEP 4: Creating Fainder index"
echo "=============================="
echo "Time estimate: 20-40 min"
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
# STEP 5: Python Baseline Benchmark
# ============================================================
echo "STEP 5: Python Baseline Benchmark"
echo "================================="
echo "Time estimate: 5-15 min"
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
# STEP 6: Rust Optimized Benchmark
# ============================================================
echo "STEP 6: Rust Optimized Benchmark"
echo "================================"
echo "Time estimate: 1-5 min"
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
echo "FINAL RESULTS - EVAL_MEDIUM (Fast, No Collation)"
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
  echo "✅ EXCELLENT: Speedup > 10x (18x target within range!)"
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
echo "Total: ${hours}h ${minutes}m ${seconds}s"
echo ""

echo "📁 DATASET INFO"
echo "==============="
echo "Histograms: $(du -sh $DATA_DIR/histograms.zst | cut -f1)"
echo "Queries: 5,000"
echo "Index: $(du -sh $DATA_DIR/indices/best_config_rebinning.zst | cut -f1)"
echo ""

echo "=============================================================="
echo "✅ EVAL_MEDIUM FAST BENCHMARK COMPLETE"
echo "=============================================================="
echo ""
echo "Summary:"
echo "  • No collation (skipped ~2+ hour validation step)"
echo "  • Pure speed comparison: Python vs Rust"
echo "  • Shows ${speedup}x speedup on eval_medium dataset"
echo "  • Complements dev_small (20x) and eval_10gb (6x)"
echo ""
