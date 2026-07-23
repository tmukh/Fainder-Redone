#!/bin/bash
# NUMA pinning ablation: numactl --membind=0 --cpunodebind=0 vs unpinned.
#
# Runs a thread sweep with and without NUMA pinning to node 0 (96 cores).
# Uses --suppress-results so timings reflect query execution only.
#
# Usage:
#   bash scripts/ablation_numa.sh [eval_medium|dev_small|eval_10gb]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-eval_medium}"
case "$DATASET" in
  dev_small)   DATA_DIR="/local-data/abumukh/data/gittables/dev_small" ;;
  eval_medium) DATA_DIR="/local-data/abumukh/data/gittables/eval_medium" ;;
  eval_10gb)   DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb" ;;
  *) echo "Unknown dataset: $DATASET"; exit 1 ;;
esac
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="$DATA_DIR/queries/all.zst"

LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"

THREADS=(1 4 16 64)

# Ensure default SoA build is active
maturin develop --release -q 2>&1 | tail -1

echo "========================================"
echo "NUMA ablation: $DATASET"
echo "========================================"

for pin in "pinned" "unpinned"; do
    for t in "${THREADS[@]}"; do
        LOG="$LOG_DIR/${DATASET}-numa-${pin}-t${t}.log"
        echo "  [$pin] t=$t -> $LOG"
        if [[ "$pin" == "pinned" ]]; then
            FAINDER_NUM_THREADS=$t numactl --membind=0 --cpunodebind=0 \
                run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
                    --suppress-results --log-level INFO --log-file "$LOG" \
                    && echo "    OK" || echo "    FAILED"
        else
            FAINDER_NUM_THREADS=$t \
                run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
                    --suppress-results --log-level INFO --log-file "$LOG" \
                    && echo "    OK" || echo "    FAILED"
        fi
    done
done

echo ""
echo "========================================"
echo "NUMA Ablation Summary (suppress_results=True)"
echo "========================================"
printf "%-8s %-12s %-12s %-10s\n" "Threads" "Pinned (s)" "Unpinned (s)" "Improvement"
printf "%-8s %-12s %-12s %-10s\n" "-------" "----------" "-----------" "-----------"
for t in "${THREADS[@]}"; do
    pinned=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-numa-pinned-t${t}.log" 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' || echo "N/A")
    unpinned=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-numa-unpinned-t${t}.log" 2>/dev/null | grep -oP '[0-9]+\.[0-9]+' || echo "N/A")
    if [[ "$pinned" != "N/A" && "$unpinned" != "N/A" ]]; then
        improvement=$(python3 -c "print(f'{(1 - $pinned/$unpinned)*100:.1f}%')")
    else
        improvement="N/A"
    fi
    printf "%-8s %-12s %-12s %-10s\n" "$t" "$pinned" "$unpinned" "$improvement"
done
