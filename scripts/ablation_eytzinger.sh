#!/bin/bash
# Ablation study: Eytzinger (BFS) layout vs default SoA layout.
# Builds --features eytzinger and sweeps thread count 1→64.
# Uses --suppress-results so only Rust query computation is timed.
#
# Usage:
#   bash scripts/ablation_eytzinger.sh [dev_small|eval_medium|eval_10gb]

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
echo "Eytzinger vs SoA ablation: $DATASET"
echo "========================================"

for label in soa eytzinger; do
    if [[ "$label" == "soa" ]]; then
        echo "[$DATASET] Building: SoA (default)..."
        maturin develop --release -q 2>&1 | tail -1
    else
        echo "[$DATASET] Building: Eytzinger (--features eytzinger)..."
        maturin develop --release --features eytzinger -q 2>&1 | tail -1
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

# Restore default build
maturin develop --release -q 2>&1 | tail -1
echo "[$DATASET] done, default build restored"

echo ""
echo "=== Timing Summary ==="
printf "%-20s %-8s %-12s %s\n" "Layout" "Threads" "Total(s)" "run_queries(s)"
for label in soa eytzinger; do
    for t in "${THREAD_COUNTS[@]}"; do
        log="$LOG_DIR/$DATASET-$label-t$t.log"
        [[ -f "$log" ]] || continue
        total=$(grep "Ran.*queries in" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+(?=s)')
        qtime=$(grep "Rust index-based query execution time" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        printf "%-20s %-8s %-12s %s\n" "$label" "t=$t" "${total:-N/A}s" "${qtime:-N/A}s"
    done
done
