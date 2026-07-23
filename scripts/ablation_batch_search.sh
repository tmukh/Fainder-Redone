#!/bin/bash
# Ablation: serial binary search vs 8-way batch binary search (columnar engine).
#
# Both runs use FAINDER_COLUMNAR=1 and suppress_results.
# serial  — default build (partition_point per query)
# batch   — --features batch-search (8 searches in lock-step per group)
#
# Usage:
#   bash scripts/ablation_batch_search.sh [dev_small|eval_medium|eval_10gb]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export FAINDER_COLUMNAR=1

DATASET="${1:-eval_medium}"
DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"

QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

if [[ -f "data/$DATASET/indices/best_config_rebinning.zst" ]]; then
    INDEX_PATH="data/$DATASET/indices/best_config_rebinning.zst"
else
    INDEX_PATH="$DATA_BASE/$DATASET/indices/best_config_rebinning.zst"
fi
# Prefer mmap .fidx if available
FIDX="${INDEX_PATH%.zst}.fidx"
if [[ -d "$FIDX" ]]; then
    LOAD_ARG="$FIDX"
else
    LOAD_ARG="$INDEX_PATH"
fi

THREAD_COUNTS=(1 2 4 8 16 32 64)

echo "========================================"
echo "Batch-search ablation: $DATASET"
echo "  index: $LOAD_ARG"
echo "========================================"

for label in serial batch; do
    if [[ "$label" == "batch" ]]; then
        echo ""
        echo "Rebuilding with --features batch-search ..."
        maturin develop --release --features batch-search 2>&1 | grep -E "Compiling|Finished|Installed"
    else
        echo ""
        echo "Rebuilding default (serial) ..."
        maturin develop --release 2>&1 | grep -E "Compiling|Finished|Installed"
    fi

    echo ""
    echo "--- $label ---"
    for t in "${THREAD_COUNTS[@]}"; do
        LOG="$LOG_DIR/${DATASET}-${label}-t${t}.log"
        FAINDER_NUM_THREADS=$t run-queries \
            -i "$LOAD_ARG" -t index \
            -q "$QUERIES" -m recall \
            --suppress-results \
            --log-level DEBUG \
            --log-file "$LOG" \
            2>/dev/null
        time_s=$(grep "Rust index-based query execution time:" "$LOG" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        echo "  t=$t : ${time_s}s"
    done
done

echo ""
echo "========================================"
echo "Summary"
echo "  $(printf '%-8s' 'Threads') $(printf '%12s' 'serial (s)') $(printf '%12s' 'batch (s)') $(printf '%10s' 'speedup')"
for t in "${THREAD_COUNTS[@]}"; do
    s_log="$LOG_DIR/${DATASET}-serial-t${t}.log"
    b_log="$LOG_DIR/${DATASET}-batch-t${t}.log"
    s_t=$(grep "Rust index-based query execution time:" "$s_log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    b_t=$(grep "Rust index-based query execution time:" "$b_log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    speedup=$(python3 -c "print(f'{float(\"$s_t\")/float(\"$b_t\"):.2f}x')" 2>/dev/null || echo "?")
    echo "  $(printf '%-8s' "t=$t") $(printf '%12s' "${s_t}s") $(printf '%12s' "${b_t}s") $(printf '%10s' "$speedup")"
done
echo "========================================"

# Rebuild default so subsequent scripts use the normal build
echo ""
echo "Restoring default build ..."
maturin develop --release 2>&1 | grep -E "Compiling|Finished|Installed"
