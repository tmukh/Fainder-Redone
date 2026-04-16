#!/bin/bash
# Ablation study: Rayon thread-count sweep for Fainder Rust engine.
# Measures parallelism contribution by varying FAINDER_NUM_THREADS from 1 to max.
#
# Usage:
#   bash scripts/ablation_parallel.sh [dev_small|eval_10gb]
#
# Output: logs/ablation/<dataset>-rust-tN.log

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASET="${1:-dev_small}"
DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"

QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

# Use repo symlink for rebinning index if available, else external path
if [[ -f "data/$DATASET/indices/best_config_rebinning.zst" ]]; then
    INDEX_R="data/$DATASET/indices/best_config_rebinning.zst"
else
    INDEX_R="$DATA_BASE/$DATASET/indices/best_config_rebinning.zst"
fi

if [[ ! -f "$INDEX_R" ]]; then
    echo "Index not found: $INDEX_R"
    exit 1
fi

echo "Ablation study: parallelism scaling on $DATASET"
echo "Index: $INDEX_R"
echo "Queries: $QUERIES"
echo ""

start_time=$(date +%s)

# Sweep thread counts: 1 (serial), 2, 4, 8, 16, 32, 64
THREAD_COUNTS=(1 2 4 8 16 32 64)

for n_threads in "${THREAD_COUNTS[@]}"; do
    echo "[$DATASET] Running with $n_threads thread(s)..."
    FAINDER_NUM_THREADS=$n_threads run-queries \
        -i "$INDEX_R" \
        -t index \
        -q "$QUERIES" \
        -m recall \
        --log-level INFO \
        --log-file "$LOG_DIR/$DATASET-rust-t$n_threads.log" \
        || echo "[$DATASET] t=$n_threads FAILED"
    echo "  → logged to $LOG_DIR/$DATASET-rust-t$n_threads.log"
done

# Also run Python baseline (single-threaded reference)
echo "[$DATASET] Running Python baseline (reference)..."
FAINDER_NO_RUST=1 run-queries \
    -i "$INDEX_R" \
    -t index \
    -q "$QUERIES" \
    -m recall \
    --log-level INFO \
    --log-file "$LOG_DIR/$DATASET-python-baseline.log" \
    || echo "[$DATASET] Python baseline FAILED"

end_time=$(date +%s)
echo ""
echo "Ablation complete in $((end_time - start_time))s"
echo ""

# Print timing summary by parsing query_collection_time from logs
echo "=== Timing Summary ==="
echo "Dataset: $DATASET"
printf "%-20s %s\n" "Method" "Time (s)"
printf "%-20s %s\n" "------" "--------"

for n_threads in "${THREAD_COUNTS[@]}"; do
    log="$LOG_DIR/$DATASET-rust-t$n_threads.log"
    if [[ -f "$log" ]]; then
        t=$(grep "Raw index-based query execution time" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        printf "%-20s %s\n" "Rust (t=$n_threads)" "${t:-N/A}"
    fi
done

log="$LOG_DIR/$DATASET-python-baseline.log"
if [[ -f "$log" ]]; then
    t=$(grep "Raw index-based query execution time" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    printf "%-20s %s\n" "Python (baseline)" "${t:-N/A}"
fi
