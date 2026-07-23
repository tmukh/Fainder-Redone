#!/bin/bash

# ============================================================================
# FAINDER 10GB EVALUATION DATASET - COMPLETE PIPELINE
# ============================================================================
# Complete ordered commands to:
# 1. Create 10GB test dataset (via sampling)
# 2. Generate all .zst files (histograms, distributions, clustering, queries, index)
# 3. Compare Python vs Rust benchmarks
#
# Time estimate: ~10-12 hours total
# ============================================================================

set -euxo pipefail

# Environment setup for high-core systems
export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export OPENBLAS_CORETYPE=HASWELL

cd /home/abumukh-ldap/fainder-redone

echo "============================================================================"
echo "FAINDER 10GB EVALUATION - COMPLETE PIPELINE"
echo "============================================================================"
echo "Time: $(date)"
echo "Estimated duration: 10-12 hours"
echo ""

# ============================================================================
# STEP 1: SETUP DIRECTORIES & VARIABLES
# ============================================================================
echo "STEP 1: Setup directories and variables"
echo "========================================"

DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"
LOCAL_SYMLINK_DIR="/home/abumukh-ldap/fainder-redone/data/eval_10gb"
INPUT_DIR="/local-data/abumukh/data/gittables/pq"

# Sample fraction for ~10GB: 0.065 (6.5%)
# This should give us roughly 10GB of histogram data
SAMPLE_FRACTION="0.065"

# Configuration parameters
KMEANS_K="80"          # Between eval_small (50) and eval_medium (100)
NUM_BINS="40000"       # Between eval_small (10k) and eval_medium (50k)
N_PERCENTILES="30"     # Between eval_small (20) and eval_medium (50)
N_REFERENCES="75"      # Between eval_small (50) and eval_medium (100)

mkdir -p "$DATA_DIR"
mkdir -p "$LOCAL_SYMLINK_DIR"

echo "Data directory: $DATA_DIR"
echo "Local symlink directory: $LOCAL_SYMLINK_DIR"
echo "Sample fraction: $SAMPLE_FRACTION (6.5%)"
echo ""

start_time=$(date +%s)

# ============================================================================
# STEP 2: COMPUTE HISTOGRAMS
# ============================================================================
echo "STEP 2: Computing histograms from parquet files"
echo "==============================================="
echo "Time estimate: 5-10 minutes"
echo "Started: $(date)"
echo ""

compute-histograms \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/histograms.zst" \
  -f "$SAMPLE_FRACTION" \
  --bin-range 10 20 \
  -w 192

echo "✓ Histograms complete!"
echo "File: $DATA_DIR/histograms.zst"
du -sh "$DATA_DIR/histograms.zst"
echo ""

# ============================================================================
# STEP 3: COMPUTE DISTRIBUTIONS (GROUND TRUTH)
# ============================================================================
echo "STEP 3: Computing ground truth distributions"
echo "============================================="
echo "Time estimate: 15-20 minutes"
echo "Started: $(date)"
echo ""

compute-distributions \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/normal_dists.zst" \
  -k normal \
  -w 192

echo "✓ Distributions complete!"
echo "File: $DATA_DIR/normal_dists.zst"
du -sh "$DATA_DIR/normal_dists.zst"
echo ""

# ============================================================================
# STEP 4: CLUSTER HISTOGRAMS
# ============================================================================
echo "STEP 4: Clustering histograms (K=$KMEANS_K)"
echo "==========================================="
echo "Time estimate: 45-75 minutes"
echo "Started: $(date)"
echo ""

cluster-histograms \
  -i "$DATA_DIR/histograms.zst" \
  -o "$DATA_DIR/clustering.zst" \
  -a kmeans \
  -c "$KMEANS_K" "$KMEANS_K" \
  -b "$NUM_BINS" \
  -t quantile \
  --alpha 1 \
  --seed 42 \
  --log-level INFO

echo "✓ Clustering complete!"
echo "File: $DATA_DIR/clustering.zst"
du -sh "$DATA_DIR/clustering.zst"
echo ""

# ============================================================================
# STEP 5: CREATE SYMLINKS FOR COLLATE SCRIPT
# ============================================================================
echo "STEP 5: Creating symlinks for collate script"
echo "==========================================="
echo ""

ln -sf "$DATA_DIR/histograms.zst" "$LOCAL_SYMLINK_DIR/histograms.zst"
ln -sf "$DATA_DIR/clustering.zst" "$LOCAL_SYMLINK_DIR/clustering.zst"
ln -sf "$DATA_DIR/queries" "$LOCAL_SYMLINK_DIR/queries" 2>/dev/null || true

mkdir -p "$DATA_DIR/queries"

echo "✓ Symlinks created"
echo ""

# ============================================================================
# STEP 6: GENERATE BENCHMARK QUERIES
# ============================================================================
echo "STEP 6: Generating benchmark queries"
echo "===================================="
echo "Time estimate: <1 minute"
echo "Started: $(date)"
echo ""

generate-queries \
  -o "$DATA_DIR/queries/all.zst" \
  --n-percentiles "$N_PERCENTILES" \
  --n-reference-values "$N_REFERENCES" \
  --seed 42 \
  --reference-value-range "-10000" "10000"

echo "✓ Queries generated!"
echo "File: $DATA_DIR/queries/all.zst"
du -sh "$DATA_DIR/queries/all.zst"
echo ""

# ============================================================================
# STEP 7: COLLATE QUERIES (ATTACH GROUND TRUTH)
# ============================================================================
echo "STEP 7: Collating queries with ground truth"
echo "=========================================="
echo "Time estimate: 30-60 minutes"
echo "Started: $(date)"
echo ""

python3 experiments/collate_benchmark_queries.py \
  -d eval_10gb \
  -q "$DATA_DIR/queries/all.zst" \
  -c "$DATA_DIR/clustering.zst" \
  -w 64

echo "✓ Queries collated!"
echo "Results saved to: $DATA_DIR/results/"
echo ""

# ============================================================================
# STEP 8: CREATE FAINDER INDEX
# ============================================================================
echo "STEP 8: Creating Fainder index (Rebinning mode)"
echo "=============================================="
echo "Time estimate: 15-30 minutes"
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

# ============================================================================
# STEP 9: PYTHON BASELINE BENCHMARK
# ============================================================================
echo "STEP 9: Running Python baseline benchmark"
echo "========================================"
echo "Time estimate: 2-10 minutes (depending on query count)"
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

# ============================================================================
# STEP 10: RUST OPTIMIZED BENCHMARK
# ============================================================================
echo "STEP 10: Running Rust optimized benchmark"
echo "========================================"
echo "Time estimate: 0.1-1 minute (much faster!)"
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

# ============================================================================
# FINAL RESULTS
# ============================================================================
end_time=$(date +%s)
total_duration=$((end_time - start_time))

echo ""
echo "============================================================================"
echo "FINAL RESULTS - 10GB EVALUATION DATASET"
echo "============================================================================"
echo ""
echo "📊 BENCHMARK COMPARISON"
echo "======================"
echo "Python baseline: ${python_time}s"
echo "Rust optimized: ${rust_time}s"
speedup=$(echo "scale=2; $python_time / $rust_time" | bc)
echo ""
echo "🎯 SPEEDUP: ${speedup}x"
echo ""

if (( $(echo "$speedup > 10" | bc -l) )); then
  echo "✅ EXCELLENT: Speedup > 10x"
elif (( $(echo "$speedup > 5" | bc -l) )); then
  echo "✅ GOOD: Speedup > 5x"
else
  echo "⚠️  MODERATE: Speedup ${speedup}x"
fi

echo ""
echo "⏱️  TOTAL PIPELINE TIME"
echo "======================"
hours=$((total_duration / 3600))
minutes=$(( (total_duration % 3600) / 60 ))
seconds=$((total_duration % 60))
echo "Duration: ${hours}h ${minutes}m ${seconds}s"
echo ""

echo "📁 OUTPUT FILES"
echo "==============="
echo "Histograms: $DATA_DIR/histograms.zst ($(du -sh $DATA_DIR/histograms.zst | cut -f1))"
echo "Clustering: $DATA_DIR/clustering.zst ($(du -sh $DATA_DIR/clustering.zst | cut -f1))"
echo "Queries: $DATA_DIR/queries/all.zst ($(du -sh $DATA_DIR/queries/all.zst | cut -f1))"
echo "Index: $DATA_DIR/indices/best_config_rebinning.zst ($(du -sh $DATA_DIR/indices/best_config_rebinning.zst | cut -f1))"
echo ""

echo "============================================================================"
echo "✅ COMPLETE - 10GB EVALUATION PIPELINE FINISHED"
echo "============================================================================"
echo ""
