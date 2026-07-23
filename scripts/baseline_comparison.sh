#!/bin/bash
# Baseline comparison: exact/ndist/binsort/pscan vs Fainder (Python + Rust)
# across all three available dataset sizes.
#
# All methods use run-queries (no ground truth required — timing only).
# PScan uses compute_pscan_results.py (also no GT needed).
#
# Usage:
#   bash scripts/baseline_comparison.sh [dev_small|eval_10gb|eval_medium|all]
#
# Output: logs/baseline_comparison/<dataset>-<method>.log

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASETS=("${1:-all}")
if [[ "${DATASETS[0]}" == "all" ]]; then
    DATASETS=("dev_small" "eval_10gb" "eval_medium")
fi

DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/baseline_comparison"
mkdir -p "$LOG_DIR"

start_time=$(date +%s)

for dataset in "${DATASETS[@]}"; do
    echo "========================================"
    echo "Dataset: $dataset  ($(date '+%H:%M:%S'))"
    echo "========================================"

    HIST="$DATA_BASE/$dataset/histograms.zst"
    NDISTS="$DATA_BASE/$dataset/normal_dists.zst"
    BINSORT="$DATA_BASE/$dataset/binsort.zst"
    QUERIES="$DATA_BASE/$dataset/queries/all.zst"

    # Rebinning index: prefer repo symlink if it exists, else external path
    if [[ -f "data/$dataset/indices/best_config_rebinning.zst" ]]; then
        INDEX_R="data/$dataset/indices/best_config_rebinning.zst"
    else
        INDEX_R="$DATA_BASE/$dataset/indices/best_config_rebinning.zst"
    fi
    INDEX_C="$DATA_BASE/$dataset/indices/best_config_conversion.zst"

    # --- 1. Exact / iterative scan (Python, no index) ---
    echo "[$dataset] 1/8 exact scan..."
    run-queries \
        -i "$HIST" -t histograms -q "$QUERIES" -e over \
        --log-level INFO \
        --log-file "$LOG_DIR/$dataset-exact.log" \
        && echo "[$dataset] exact OK" || echo "[$dataset] exact FAILED"

    # --- 2. BinSort ---
    if [[ -f "$BINSORT" ]]; then
        echo "[$dataset] 2/8 binsort..."
        run-queries \
            -i "$BINSORT" -t binsort -q "$QUERIES" -m recall \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-binsort.log" \
            && echo "[$dataset] binsort OK" || echo "[$dataset] binsort FAILED"
    else
        echo "[$dataset] 2/8 binsort SKIPPED (no $BINSORT)"
    fi

    # --- 3. NormalDist (ndist) via run-queries ---
    if [[ -f "$NDISTS" ]]; then
        echo "[$dataset] 3/8 ndist..."
        run-queries \
            -i "$NDISTS" -t normal_dists -q "$QUERIES" \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-ndist.log" \
            && echo "[$dataset] ndist OK" || echo "[$dataset] ndist FAILED"
    else
        echo "[$dataset] 3/8 ndist SKIPPED (no $NDISTS)"
    fi

    # --- 4. PScan (custom script, no GT needed) ---
    echo "[$dataset] 4/8 pscan..."
    python experiments/compute_pscan_results.py \
        -H "$HIST" -q "$QUERIES" \
        -w "$(nproc)" \
        --log-level INFO \
        --log-file "$LOG_DIR/$dataset-pscan.zst" \
        && echo "[$dataset] pscan OK" || echo "[$dataset] pscan FAILED"

    # --- 5. Fainder Python rebinning ---
    if [[ -f "$INDEX_R" ]]; then
        echo "[$dataset] 5/8 Fainder Python rebinning..."
        FAINDER_NO_RUST=1 run-queries \
            -i "$INDEX_R" -t index -q "$QUERIES" -m recall \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-fainder-python-rebinning.log" \
            && echo "[$dataset] Fainder Python rebinning OK" || echo "FAILED"
    fi

    # --- 6. Fainder Rust rebinning ---
    if [[ -f "$INDEX_R" ]]; then
        echo "[$dataset] 6/8 Fainder Rust rebinning..."
        run-queries \
            -i "$INDEX_R" -t index -q "$QUERIES" -m recall \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-fainder-rust-rebinning.log" \
            && echo "[$dataset] Fainder Rust rebinning OK" || echo "FAILED"
    fi

    # --- 7. Fainder Python conversion ---
    if [[ -f "$INDEX_C" ]]; then
        echo "[$dataset] 7/8 Fainder Python conversion..."
        FAINDER_NO_RUST=1 run-queries \
            -i "$INDEX_C" -t index -q "$QUERIES" -m recall \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-fainder-python-conversion.log" \
            && echo "[$dataset] Fainder Python conversion OK" || echo "FAILED"
    else
        echo "[$dataset] 7/8 Fainder Python conversion SKIPPED (index not ready)"
    fi

    # --- 8. Fainder Rust conversion ---
    if [[ -f "$INDEX_C" ]]; then
        echo "[$dataset] 8/8 Fainder Rust conversion..."
        run-queries \
            -i "$INDEX_C" -t index -q "$QUERIES" -m recall \
            --log-level INFO \
            --log-file "$LOG_DIR/$dataset-fainder-rust-conversion.log" \
            && echo "[$dataset] Fainder Rust conversion OK" || echo "FAILED"
    else
        echo "[$dataset] 8/8 Fainder Rust conversion SKIPPED (index not ready)"
    fi

    echo "[$dataset] Done at $(date '+%H:%M:%S')"
    echo ""
done

end_time=$(date +%s)
echo "========================================"
echo "All done in $((end_time - start_time))s"
echo "Results in: $LOG_DIR/"
echo "========================================"

# Quick timing summary
echo ""
echo "=== TIMING SUMMARY ==="
printf "%-15s %-35s %s\n" "Dataset" "Method" "Time(s)"
printf "%-15s %-35s %s\n" "-------" "------" "-------"
for dataset in "${DATASETS[@]}"; do
    for method in exact binsort ndist fainder-python-rebinning fainder-rust-rebinning fainder-python-conversion fainder-rust-conversion; do
        log="$LOG_DIR/$dataset-$method.log"
        if [[ -f "$log" ]]; then
            t=$(grep -oP "(?<=execution time: )[0-9]+\.[0-9]+" "$log" | tail -1)
            [[ -z "$t" ]] && t=$(grep -oP "(?<=queries in )[0-9]+\.[0-9]+" "$log" | tail -1)
            printf "%-15s %-35s %s\n" "$dataset" "$method" "${t:-N/A}"
        fi
    done
done
