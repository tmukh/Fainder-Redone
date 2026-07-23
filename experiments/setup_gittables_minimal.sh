#!/bin/bash

# MINIMAL GITTABLES SETUP FOR TESTING
# ====================================
# This script sets up a small subset of GitTables for quick testing
# of the Fainder optimization pipeline.
#
# Usage: bash experiments/setup_gittables_minimal.sh [--full]
#   (no args) = dev_small setup (~2 hours)
#   --full    = eval_medium setup (~24 hours)

set -euxo pipefail
ulimit -Sn 10000

# Fix OpenBLAS threading issues on high-core systems
export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export OPENBLAS_CORETYPE=HASWELL

cd "$(git rev-parse --show-toplevel)"

start_time=$(date +%s)
log_level=INFO
nproc=$(nproc)

# Determine setup size
SETUP_TYPE="${1:-dev_small}"

case "$SETUP_TYPE" in
  dev_small)
    echo "Setting up dev_small (minimal, ~2 hours)"
    INPUT_DIR="/local-data/abumukh/data/gittables/pq"
    OUTPUT_PREFIX="dev_small"
    SAMPLE_FRACTION="0.01"  # 1% sample for fast testing
    KMEANS_K="10"
    NUM_BINS="1000"
    N_PERCENTILES="10"
    N_REFERENCES="10"
    DATA_DIR="/local-data/abumukh/data/gittables/dev_small"
    ;;
  eval_small)
    echo "Setting up eval_small (small eval, ~4 hours)"
    INPUT_DIR="/local-data/abumukh/data/gittables/pq"
    OUTPUT_PREFIX="eval_small"
    SAMPLE_FRACTION="0.05"  # 5% sample
    KMEANS_K="50"
    NUM_BINS="10000"
    N_PERCENTILES="20"
    N_REFERENCES="50"
    DATA_DIR="/local-data/abumukh/data/gittables/eval_small"
    ;;
  eval_medium)
    echo "Setting up eval_medium (medium eval, ~24 hours)"
    INPUT_DIR="/local-data/abumukh/data/gittables/pq"
    OUTPUT_PREFIX="eval_medium"
    SAMPLE_FRACTION="0.2"  # 20% sample
    KMEANS_K="100"
    NUM_BINS="50000"
    N_PERCENTILES="50"
    N_REFERENCES="100"
    DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"
    ;;
  *)
    echo "Usage: $0 [dev_small|eval_small|eval_medium|--full]"
    exit 1
    ;;
esac

echo "Setup Type: $SETUP_TYPE"
echo "Input Directory: $INPUT_DIR"
echo "Output Prefix: $OUTPUT_PREFIX"
echo "Sample Fraction: $SAMPLE_FRACTION (${SAMPLE_FRACTION%.*}%)"
echo ""

# Verify input exists
if [ ! -d "$INPUT_DIR" ]; then
  echo "ERROR: Input directory $INPUT_DIR does not exist"
  exit 1
fi

echo "Step 1: Creating output directory..."
mkdir -p "$DATA_DIR"

# Step 1: Compute Histograms
echo ""
echo "Step 2: Computing histograms from parquet files..."
echo "  This may take 10-60 minutes depending on sample size..."
compute-histograms \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/histograms.zst" \
  -f "$SAMPLE_FRACTION" \
  --bin-range 10 20 \
  -w "$nproc"

echo "Step 3: Computing ground truth distributions..."
compute-distributions \
  -i "$INPUT_DIR" \
  -o "$DATA_DIR/normal_dists.zst" \
  -k normal \
  -w "$nproc"

# Step 2: Cluster Histograms
echo ""
echo "Step 4: Clustering histograms for index configuration..."
echo "  Using K=$KMEANS_K (adjust KMEANS_K variable if needed)"
cluster-histograms \
  -i "$DATA_DIR/histograms.zst" \
  -o "$DATA_DIR/clustering.zst" \
  -a kmeans \
  -c "$KMEANS_K" "$KMEANS_K" \
  -b "$NUM_BINS" \
  -t quantile \
  --alpha 1 \
  --seed 42 \
  --log-level "$log_level"

# Step 3: Generate Queries
echo ""
echo "Step 5: Generating benchmark queries..."
mkdir -p "$DATA_DIR/queries"

generate-queries \
  -o "$DATA_DIR/queries/all.zst" \
  --n-percentiles "$N_PERCENTILES" \
  --n-reference-values "$N_REFERENCES" \
  --seed 42 \
  --reference-value-range "-10000" "10000" \
  --log-level "$log_level"

# Step 4: Collate Queries (Compute ground truth)
echo ""
echo "Step 6: Collating queries against ground truth..."
python experiments/collate_benchmark_queries.py \
  -d "$(basename $DATA_DIR)" \
  -q "$DATA_DIR/queries/all.zst" \
  -c "$DATA_DIR/clustering.zst" \
  -w "$nproc" \
  --log-level "$log_level"

# Step 5: Create Indexes (Rebinning mode)
echo ""
echo "Step 7: Creating Fainder index (Rebinning mode)..."
mkdir -p "$DATA_DIR/indices"

create-index \
  -i "$DATA_DIR/clustering.zst" \
  -m rebinning \
  -p float32 \
  -o "$DATA_DIR/indices" \
  --index-file best_config_rebinning.zst \
  --log-level "$log_level"

# Optional: Create Conversion mode index (slower, higher accuracy)
# Uncomment if needed:
# echo "Step 8 (Optional): Creating Fainder index (Conversion mode)..."
# create-index \
#   -i "$DATA_DIR/clustering.zst" \
#   -m conversion \
#   -p float32 \
#   -o "$DATA_DIR/indices" \
#   --index-file best_config_conversion.zst \
#   --log-level "$log_level"

# Success message
end_time=$(date +%s)
duration=$((end_time - start_time))
hours=$((duration / 3600))
minutes=$(( (duration % 3600) / 60 ))
seconds=$((duration % 60))

echo ""
echo "=========================================="
echo "✓ Setup Complete!"
echo "=========================================="
echo "Duration: ${hours}h ${minutes}m ${seconds}s"
echo ""
echo "Output Directory: $DATA_DIR"
echo "Ready for benchmarking with:"
echo ""
echo "  run-queries \\"
echo "    -i $DATA_DIR/indices/best_config_rebinning.zst \\"
echo "    -t index \\"
echo "    -q $DATA_DIR/queries/all.zst \\"
echo "    -m recall \\"
echo "    --workers $nproc"
echo ""
