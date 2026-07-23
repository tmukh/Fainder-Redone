#!/bin/bash
# Ablation: pre-allocated per-query output Vec (--features pooled) vs default
# flat_map+collect pattern.
#
# Per the per-line perf analysis (FAINDER_DEEP_DIVE.md Part 4), 30% of cycles
# in the row-centric engine are inside FlatMap::next, which fuses the binary
# search with per-cluster Vec<u32> allocation and memcpy. The pooled variant
# replaces those with a single per-query buffer + extend_from_slice.
#
# Usage:
#   bash scripts/ablation_pooled.sh [eval_medium|dev_small]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASET="${1:-eval_medium}"
case "$DATASET" in
  dev_small)   DATA_DIR="/local-data/abumukh/data/gittables/dev_small"
               INDEX="/home/abumukh-ldap/fainder-redone/data/dev_small/indices/best_config_rebinning.zst" ;;
  eval_medium) DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"
               INDEX="$DATA_DIR/indices/best_config_rebinning.zst" ;;
  *) echo "Unknown dataset: $DATASET"; exit 1 ;;
esac
QUERIES="$DATA_DIR/queries/all.zst"

LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"
THREADS=(1 2 4 8 16 32 64)

run_sweep() {
    local label="$1"
    echo ""
    echo "[$DATASET/$label] Thread sweep: ${THREADS[*]}"
    for t in "${THREADS[@]}"; do
        local log="$LOG_DIR/${DATASET}-${label}-t${t}.log"
        echo "  t=$t -> $log"
        FAINDER_NUM_THREADS=$t run-queries \
            -i "$INDEX" -t index -q "$QUERIES" -m recall \
            --suppress-results --log-level INFO --log-file "$log" \
            && echo "    OK" || echo "    FAILED"
    done
}

echo "========================================"
echo "STEP 1: Default (flat_map + collect)"
echo "========================================"
maturin develop --release -q 2>&1 | tail -1
run_sweep "default-out"

echo ""
echo "========================================"
echo "STEP 2: --features pooled (pre-allocated per-query Vec)"
echo "========================================"
maturin develop --release --features pooled -q 2>&1 | tail -1
run_sweep "pooled"

# Restore default
echo ""
echo "Restoring default build..."
maturin develop --release -q 2>&1 | tail -1

# Summary
echo ""
echo "========================================"
echo "Summary — ${DATASET}, suppress_results=True"
echo "========================================"
printf "%-8s %-14s %-14s %-10s\n" "Threads" "Default (s)" "Pooled (s)" "Speedup"
for t in "${THREADS[@]}"; do
    def_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-default-out-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    pooled_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-pooled-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    if [[ -n "$def_t" && -n "$pooled_t" ]]; then
        speedup=$(python3 -c "print(f'{$def_t / $pooled_t:.2f}x')")
    else
        speedup="N/A"
    fi
    printf "%-8s %-14s %-14s %-10s\n" "t=$t" "${def_t:-N/A}" "${pooled_t:-N/A}" "$speedup"
done
