#!/bin/bash
# Ablation study: scalar partition_point vs AVX2-vectorized binary search.
#
# Hypothesis: SIMD replaces 3 scalar compare-and-branch steps with one AVX2
# VCMPPS + MOVMSKPS instruction, reducing the dependent load-chain depth by ~3
# steps (12 → ~9 for n=3500). This should provide a speedup when binary search
# comparisons are the bottleneck — i.e. at LOW thread counts where the column
# data is cached and compute (not bandwidth) is the limiting factor.
# At HIGH thread counts (t≥16), DRAM bandwidth is already saturated and SIMD
# cannot help because the bottleneck is bytes/second, not ops/second.
#
# Measurement: columnar engine + suppress_results=True so we measure ONLY the
# binary search computation (column stays in L2/L3 cache = best case for SIMD).
#
# Usage:
#   bash scripts/ablation_simd.sh [dev_small|eval_medium|eval_10gb|all]
#
# Output: logs/ablation/<dataset>-{scalar,simd}-tN.log

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASET_ARG="${1:-eval_medium}"
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

    echo "[$dataset/$label] Thread sweep (columnar + suppress_results): ${THREADS[*]}"
    for t in "${THREADS[@]}"; do
        echo "  t=$t..."
        FAINDER_COLUMNAR=1 FAINDER_NUM_THREADS=$t run-queries \
            -i "$index" -t index \
            -q "$queries" -m recall \
            --suppress-results \
            --log-file "$LOG_DIR/$dataset-$label-t$t.log" \
            2>&1 | tee -a "$LOG_DIR/$dataset-$label-t$t.log" \
            | grep -E "TIMER parallel_phase|Ran " || true
    done
}

start_time=$(date +%s)

for dataset in "${DATASETS[@]}"; do
    index=$(get_index "$dataset")
    echo ""
    echo "========================================"
    echo "SIMD ablation: $dataset"
    echo "Index: $index"
    echo "========================================"

    run_sweep "scalar" ""     "$dataset" "$index"
    run_sweep "simd"   "simd" "$dataset" "$index"

    # Restore default (scalar) build
    maturin develop --release -q 2>&1 | tail -1
    echo "[$dataset] done, default scalar build restored"
done

end_time=$(date +%s)

echo ""
echo "========================================"
echo "SIMD Ablation Summary"
echo "========================================"
printf "%-14s %-8s %-8s %-14s %-12s %s\n" "Dataset" "Variant" "Threads" "rust_exec(s)" "Ran (s)" "Speedup"

# Extract "Rust index-based query execution time: X.XXXs" from Python DEBUG logger
extract_rust_exec() {
    local log="$1"
    python3 -c "
import re
try:
    m = re.search(r'Rust index-based query execution time: ([0-9.]+)s', open('$log').read())
    print(m.group(1) if m else 'N/A')
except: print('N/A')" 2>/dev/null || echo "N/A"
}

extract_ran() {
    local log="$1"
    python3 -c "
import re
try:
    # Match the timestamped INFO line only (avoids duplicate bare line from tee)
    m = re.search(r'INFO\s+\| Ran \d+ queries in ([0-9.e+]+)s', open('$log').read())
    print(m.group(1) if m else 'N/A')
except: print('N/A')" 2>/dev/null || echo "N/A"
}

for dataset in "${DATASETS[@]}"; do
    for label in scalar simd; do
        for t in "${THREADS[@]}"; do
            log="$LOG_DIR/$dataset-$label-t$t.log"
            [[ -f "$log" ]] || continue
            rust_t=$(extract_rust_exec "$log")
            ran_t=$(extract_ran "$log")

            speedup="—"
            if [[ "$label" == "simd" && "$rust_t" != "N/A" ]]; then
                scalar_log="$LOG_DIR/$dataset-scalar-t$t.log"
                s_rust=$(extract_rust_exec "$scalar_log")
                if [[ "$s_rust" != "N/A" ]]; then
                    speedup=$(awk "BEGIN{printf \"%.2fx\", $s_rust / $rust_t}")
                fi
            fi
            printf "%-14s %-8s %-8s %-14s %-12s %s\n" \
                "$dataset" "$label" "t=$t" "${rust_t}s" "${ran_t}s" "$speedup"
        done
    done
    echo ""
done

echo "Total wall time: $((end_time - start_time))s"
