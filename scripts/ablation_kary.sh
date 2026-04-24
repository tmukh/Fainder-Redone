#!/bin/bash
# Ablation: 4-way branchless search (--features kary) vs. stdlib binary search.
#
# Tests whether reducing the CMOV dependency chain (log_2(n)≈11 steps → log_4(n)≈6
# steps) accelerates the query hot path. Per-chapter-4 perf measurements, the
# engine is L1-hit-dominated (0.55% L1 miss) with IPC ≈ 2.46 at t=1; the dep
# chain is the likely remaining bottleneck.
#
# Both variants run with --suppress-results. Correctness is verified up front.
#
# Usage:
#   bash scripts/ablation_kary.sh [eval_medium|dev_small]

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
echo "STEP 1: Default (stdlib partition_point)"
echo "========================================"
maturin develop --release -q 2>&1 | tail -1
run_sweep "binary"

echo ""
echo "========================================"
echo "STEP 2: --features kary (4-way branchless)"
echo "========================================"
maturin develop --release --features kary -q 2>&1 | tail -1
run_sweep "kary"

# Restore default
echo ""
echo "Restoring default build..."
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "========================================"
echo "Summary — ${DATASET}, suppress_results=True"
echo "========================================"
printf "%-8s %-14s %-14s %-10s\n" "Threads" "Binary (s)" "4-way (s)" "Speedup"
for t in "${THREADS[@]}"; do
    bin_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-binary-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    kary_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-kary-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    if [[ -n "$bin_t" && -n "$kary_t" ]]; then
        speedup=$(python3 -c "print(f'{$bin_t / $kary_t:.2f}x')")
    else
        speedup="N/A"
    fi
    printf "%-8s %-14s %-14s %-10s\n" "t=$t" "${bin_t:-N/A}" "${kary_t:-N/A}" "$speedup"
done
