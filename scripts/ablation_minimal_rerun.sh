#!/bin/bash
# Minimal re-run of cluster-par and SoA/AoS ablations with --suppress-results.
# Runs only t=1, 16, 64 (not full sweep) to save time.
# eval_medium only.
#
# Usage:
#   bash scripts/ablation_minimal_rerun.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"

DATASET="eval_medium"
INDEX="$DATA_BASE/$DATASET/indices/best_config_rebinning.zst"
QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

THREADS=(1 16 64)

run_one() {
    local label="$1" t="$2"
    local log="$LOG_DIR/${DATASET}-${label}-t${t}.log"
    echo "  [$label] t=$t -> $log"
    FAINDER_NUM_THREADS=$t run-queries \
        -i "$INDEX" -t index -q "$QUERIES" -m recall \
        --suppress-results \
        --log-level INFO --log-file "$log" \
        && echo "    OK" || echo "    FAILED"
}

# 1. Default build (SoA) — re-run query-par at t=1, 16, 64
echo "========================================"
echo "STEP 1: SoA / query-par (default build)"
echo "========================================"
maturin develop --release -q 2>&1 | tail -1
for t in "${THREADS[@]}"; do
    run_one "query-par" "$t"
    run_one "soa" "$t"  # same data but keep old name for SoA vs AoS table
done

# 2. AoS build
echo ""
echo "========================================"
echo "STEP 2: AoS (--features aos)"
echo "========================================"
maturin develop --release --features aos -q 2>&1 | tail -1
for t in "${THREADS[@]}"; do
    run_one "aos" "$t"
done

# 3. cluster-par build
echo ""
echo "========================================"
echo "STEP 3: cluster-par (--features cluster-par)"
echo "========================================"
maturin develop --release --features cluster-par -q 2>&1 | tail -1
for t in "${THREADS[@]}"; do
    run_one "cluster-par" "$t"
done

# Restore default
echo ""
echo "Restoring default SoA build..."
maturin develop --release -q 2>&1 | tail -1

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Summary (suppress_results=True)"
echo "========================================"
printf "%-14s %-8s %-12s\n" "Config" "Threads" "Rust-idx (s)"
for config in soa aos query-par cluster-par; do
    for t in "${THREADS[@]}"; do
        log="$LOG_DIR/${DATASET}-${config}-t${t}.log"
        rust=$(grep "Rust index-based query execution time" "$log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        printf "%-14s %-8s %-12s\n" "$config" "t=$t" "${rust:-N/A}"
    done
done
