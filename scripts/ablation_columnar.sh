#!/bin/bash
# Ablation study: row-centric vs column-centric execution engine.
# Both engines use the same SoA f32 build (no feature flags needed).
# Controlled by FAINDER_COLUMNAR=0/1 environment variable.
#
# Usage:
#   bash scripts/ablation_columnar.sh [dev_small|eval_medium|eval_10gb]

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

if [[ -f "data/$DATASET/indices/best_config_rebinning.zst" ]]; then
    INDEX_R="data/$DATASET/indices/best_config_rebinning.zst"
else
    INDEX_R="$DATA_BASE/$DATASET/indices/best_config_rebinning.zst"
fi

if [[ ! -f "$INDEX_R" ]]; then
    echo "Index not found: $INDEX_R"
    exit 1
fi

THREAD_COUNTS=(1 2 4 8 16 32 64)

echo "========================================"
echo "Row-centric vs Column-centric ablation: $DATASET"
echo "========================================"

for label in row columnar; do
    if [[ "$label" == "row" ]]; then
        export FAINDER_COLUMNAR=0
    else
        export FAINDER_COLUMNAR=1
    fi

    echo "[$DATASET/$label] Thread sweep: ${THREAD_COUNTS[*]}"
    for t in "${THREAD_COUNTS[@]}"; do
        echo "  t=$t..."
        FAINDER_NUM_THREADS=$t run-queries \
            -i "$INDEX_R" -t index \
            -q "$QUERIES" -m recall \
            --suppress-results \
            --log-level DEBUG \
            --log-file "$LOG_DIR/$DATASET-$label-t$t.log" \
            && echo "  OK" || echo "  FAILED"
    done
done

unset FAINDER_COLUMNAR

echo ""
echo "=== Timing Summary ==="
printf "%-12s %-8s %-12s %s\n" "Engine" "Threads" "Total(s)" "Rust(s)"
for label in row columnar; do
    for t in "${THREAD_COUNTS[@]}"; do
        log="$LOG_DIR/$DATASET-$label-t$t.log"
        [[ -f "$log" ]] || continue
        total=$(grep "Ran.*queries in" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+(?=s)')
        qtime=$(grep "Rust index-based query execution time" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        printf "%-12s %-8s %-12s %s\n" "$label" "t=$t" "${total:-N/A}s" "${qtime:-N/A}s"
    done
done
