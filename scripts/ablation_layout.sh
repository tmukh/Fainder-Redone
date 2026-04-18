#!/bin/bash
# Ablation study: SoA vs AoS memory layout comparison.
#
# Builds two variants of the Rust engine:
#   SoA (default)  — Structure-of-Arrays: separate values[] and indices[]
#   AoS (--features aos) — Array-of-Structs: interleaved (value, index) pairs
#
# Both variants use identical Rayon parallelism, partition_point search,
# and typed query execution — only the SubIndex memory layout differs.
# Run at t=1 (serial) to isolate layout from parallelism.
#
# Usage:
#   bash scripts/ablation_layout.sh [dev_small|eval_medium|eval_10gb|all]
#
# Output: logs/ablation/<dataset>-rust-soa.log
#         logs/ablation/<dataset>-rust-aos.log

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64
export FAINDER_NUM_THREADS=1   # serial — isolates layout from parallelism

DATASET_ARG="${1:-all}"
if [[ "$DATASET_ARG" == "all" ]]; then
    DATASETS=(dev_small eval_medium eval_10gb)
else
    DATASETS=("$DATASET_ARG")
fi

DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"

# ── Helper: get index path ────────────────────────────────────────────────────
get_index() {
    local dataset="$1"
    if [[ -f "data/$dataset/indices/best_config_rebinning.zst" ]]; then
        echo "data/$dataset/indices/best_config_rebinning.zst"
    else
        echo "$DATA_BASE/$dataset/indices/best_config_rebinning.zst"
    fi
}

run_one() {
    # run_one <dataset> <index_path> <mode_label> <log_suffix>
    local dataset="$1" index_path="$2" mode_label="$3" log_suffix="$4"
    local queries="$DATA_BASE/$dataset/queries/all.zst"

    if [[ ! -f "$index_path" ]]; then
        echo "  [$dataset/$mode_label] index not found — skipping"
        return
    fi

    # SoA
    maturin develop --release -q 2>&1 | tail -1
    echo "  [$dataset/$mode_label] SoA (t=1)..."
    run-queries -i "$index_path" -t index -q "$queries" -m recall \
        --log-level INFO \
        --log-file "$LOG_DIR/$dataset-soa-$log_suffix.log" \
        && echo "  OK" || echo "  FAILED"

    # AoS
    maturin develop --release --features aos -q 2>&1 | tail -1
    echo "  [$dataset/$mode_label] AoS (t=1)..."
    run-queries -i "$index_path" -t index -q "$queries" -m recall \
        --log-level INFO \
        --log-file "$LOG_DIR/$dataset-aos-$log_suffix.log" \
        && echo "  OK" || echo "  FAILED"
}

run_layout_ablation() {
    local dataset="$1"
    local reb_path conv_path

    reb_path=$(get_index "$dataset")
    conv_path="$DATA_BASE/$dataset/indices/best_config_conversion.zst"

    echo ""
    echo "========================================"
    echo "Layout ablation: $dataset  (t=1 serial)"
    echo "========================================"

    run_one "$dataset" "$reb_path"  "rebinning"  "rebinning"
    run_one "$dataset" "$conv_path" "conversion" "conversion"

    # Restore SoA as active build
    maturin develop --release -q 2>&1 | tail -1
    echo "[$dataset] done, SoA restored"
}

# ── Run ───────────────────────────────────────────────────────────────────────
start_time=$(date +%s)

for dataset in "${DATASETS[@]}"; do
    run_layout_ablation "$dataset"
done

end_time=$(date +%s)

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Layout Ablation Summary (t=1, serial)"
echo "========================================"
printf "%-12s %-12s %-8s %-10s %s\n" "Dataset" "Mode" "Layout" "Time (s)" "vs SoA"
printf "%-12s %-12s %-8s %-10s %s\n" "-------" "----" "------" "--------" "------"

for dataset in "${DATASETS[@]}"; do
    for mode in rebinning conversion; do
        soa_t=$(python3 -c "
import re, sys
t = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$LOG_DIR/$dataset-soa-$mode.log').read())
print(t.group(1) if t else 'N/A')" 2>/dev/null || echo "N/A")
        aos_t=$(python3 -c "
import re, sys
t = re.search(r'Ran \d+ queries in ([0-9.e+]+)s', open('$LOG_DIR/$dataset-aos-$mode.log').read())
print(t.group(1) if t else 'N/A')" 2>/dev/null || echo "N/A")

        printf "%-12s %-12s %-8s %-10s\n" "$dataset" "$mode" "SoA" "${soa_t}s"
        if [[ "$soa_t" != "N/A" && "$aos_t" != "N/A" ]]; then
            ratio=$(awk "BEGIN {printf \"%.2fx slower\", $aos_t / $soa_t}")
            printf "%-12s %-12s %-8s %-10s %s\n" "" "" "AoS" "${aos_t}s" "$ratio"
        else
            printf "%-12s %-12s %-8s %-10s\n" "" "" "AoS" "${aos_t}s"
        fi
    done
done

echo ""
echo "Total time: $((end_time - start_time))s"
echo "Logs: $LOG_DIR/<dataset>-rust-{soa,aos}.log"
