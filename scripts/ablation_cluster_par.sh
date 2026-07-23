#!/bin/bash
# Ablation study: nested cluster-level parallelism vs query-level only.
#
# Three configurations, all controlled by Cargo feature flags:
#
#   query-par (default):      outer par_iter over queries, cluster loop serial
#                             Work units: n_queries
#
#   cluster-par (--features cluster-par):
#                             outer par_iter over queries + inner par_iter
#                             over clusters. Rayon work-stealing handles both
#                             levels from the same thread pool.
#                             Work units: n_queries × n_clusters (~34× more)
#
# Thread sweep 1→64 for each configuration isolates:
#   - Does more parallelism granularity break the flat curve?
#   - Or does DRAM latency dominate regardless of work units?
#
# Usage:
#   bash scripts/ablation_cluster_par.sh [dev_small|eval_medium|eval_10gb|all]
#
# Output: logs/ablation/<dataset>-query-par-tN.log
#         logs/ablation/<dataset>-cluster-par-tN.log

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASET_ARG="${1:-all}"
if [[ "$DATASET_ARG" == "all" ]]; then
    DATASETS=(dev_small eval_medium eval_10gb)
else
    DATASETS=("$DATASET_ARG")
fi

DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"
THREADS=(1 2 4 8 16 32 64)

get_index() {
    local dataset="$1"
    if [[ -f "data/$dataset/indices/best_config_rebinning.zst" ]]; then
        echo "data/$dataset/indices/best_config_rebinning.zst"
    else
        echo "$DATA_BASE/$dataset/indices/best_config_rebinning.zst"
    fi
}

run_sweep() {
    local label="$1" features="$2" dataset="$3" index="$4"
    local queries="$DATA_BASE/$dataset/queries/all.zst"

    echo ""
    echo "[$dataset] Building: $label (features='$features')..."
    if [[ -z "$features" ]]; then
        maturin develop --release -q 2>&1 | tail -1
    else
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    fi

    echo "[$dataset/$label] Thread sweep: ${THREADS[*]}"
    for t in "${THREADS[@]}"; do
        echo "  t=$t..."
        FAINDER_NUM_THREADS=$t run-queries \
            -i "$index" -t index \
            -q "$queries" -m recall \
            --suppress-results \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-$label-t$t.log" \
            && echo "  OK" || echo "  FAILED"
    done
}

start_time=$(date +%s)

for dataset in "${DATASETS[@]}"; do
    index=$(get_index "$dataset")
    echo ""
    echo "========================================"
    echo "Cluster parallelism ablation: $dataset"
    echo "Index: $index"
    echo "========================================"

    # Config 1: query-level parallelism only (default build, no features)
    run_sweep "query-par" "" "$dataset" "$index"

    # Config 2: nested query + cluster parallelism
    run_sweep "cluster-par" "cluster-par" "$dataset" "$index"

    # Restore default build
    maturin develop --release -q 2>&1 | tail -1
    echo "[$dataset] done, default build restored"
done

end_time=$(date +%s)

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Cluster Parallelism Ablation Summary"
echo "========================================"
printf "%-14s %-14s %-8s %-10s %s\n" "Dataset" "Config" "Threads" "Time (s)" "vs query-par t=1"

for dataset in "${DATASETS[@]}"; do
    # Get query-par t=1 as baseline
    baseline_log="$LOG_DIR/$dataset-query-par-t1.log"
    baseline_t=$(python3 -c "
import re
m = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$baseline_log').read())
print(m.group(1) if m else 'N/A')" 2>/dev/null || echo "N/A")

    for label in query-par cluster-par; do
        for t in "${THREADS[@]}"; do
            log="$LOG_DIR/$dataset-$label-t$t.log"
            if [[ -f "$log" ]]; then
                run_t=$(python3 -c "
import re
m = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$log').read())
print(m.group(1) if m else 'N/A')" 2>/dev/null || echo "N/A")
                if [[ "$run_t" != "N/A" && "$baseline_t" != "N/A" ]]; then
                    speedup=$(awk "BEGIN {printf \"%.2fx\", $baseline_t / $run_t}")
                else
                    speedup="N/A"
                fi
                printf "%-14s %-14s %-8s %-10s %s\n" \
                    "$dataset" "$label" "t=$t" "${run_t}s" "$speedup"
            fi
        done
    done
    echo ""
done

echo "Total time: $((end_time - start_time))s"
echo "Logs: $LOG_DIR/<dataset>-{query-par,cluster-par}-tN.log"
