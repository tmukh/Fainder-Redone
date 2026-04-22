#!/bin/bash
# Ablation study: f32 (default) vs f16 percentile value storage.
#
# f16 halves the index memory footprint (494 MB → ~247 MB for eval_medium),
# fitting more of the index into LLC. Since the workload is DRAM-latency-bound,
# reducing memory pressure should reduce LLC misses and improve throughput.
#
# Thread sweep 1→64 for both variants to see if f16 breaks the flat curve.
#
# Usage:
#   bash scripts/ablation_f16.sh [dev_small|eval_medium|eval_10gb|all]
#
# Output: logs/ablation/<dataset>-f32-tN.log
#         logs/ablation/<dataset>-f16-tN.log

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
    echo "f16 vs f32 ablation: $dataset"
    echo "Index: $index"
    echo "========================================"

    run_sweep "f32" "" "$dataset" "$index"
    run_sweep "f16" "f16" "$dataset" "$index"

    # Restore default build
    maturin develop --release -q 2>&1 | tail -1
    echo "[$dataset] done, default build restored"
done

end_time=$(date +%s)

echo ""
echo "========================================"
echo "f16 vs f32 Ablation Summary"
echo "========================================"
printf "%-14s %-8s %-8s %-10s %-10s %s\n" "Dataset" "Layout" "Threads" "Time (s)" "vs f32 t=1" "Speedup f16/f32"

for dataset in "${DATASETS[@]}"; do
    baseline_log="$LOG_DIR/$dataset-f32-t1.log"
    baseline_t=$(python3 -c "
import re
m = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$baseline_log').read())
print(m.group(1) if m else 'N/A')" 2>/dev/null || echo "N/A")

    for label in f32 f16; do
        for t in "${THREADS[@]}"; do
            log="$LOG_DIR/$dataset-$label-t$t.log"
            [[ -f "$log" ]] || continue
            run_t=$(python3 -c "
import re
m = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$log').read())
print(m.group(1) if m else 'N/A')" 2>/dev/null || echo "N/A")

            # Compare f16 vs f32 at same thread count
            f32_log="$LOG_DIR/$dataset-f32-t$t.log"
            if [[ -f "$f32_log" && "$run_t" != "N/A" ]]; then
                f32_t=$(python3 -c "
import re
m = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$f32_log').read())
print(m.group(1) if m else 'N/A')" 2>/dev/null || echo "N/A")
                if [[ "$f32_t" != "N/A" ]]; then
                    ratio=$(awk "BEGIN {printf \"%.2fx\", $f32_t / $run_t}")
                else
                    ratio="N/A"
                fi
            else
                ratio=""
            fi

            vs_base="N/A"
            if [[ "$run_t" != "N/A" && "$baseline_t" != "N/A" ]]; then
                vs_base=$(awk "BEGIN {printf \"%.2fx\", $baseline_t / $run_t}")
            fi
            printf "%-14s %-8s %-8s %-10s %-10s %s\n" \
                "$dataset" "$label" "t=$t" "${run_t}s" "$vs_base" "$ratio"
        done
    done
    echo ""
done

echo "Total time: $((end_time - start_time))s"
