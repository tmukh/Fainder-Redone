#!/bin/bash
# Re-run the headline ablations with target-cpu=native (added 2026-04-27 via
# .cargo/config.toml). Prior ablations were on a generic x86-v1 binary; this
# fixes that systematic blind spot.
#
# Runs the three configs that define our headline:
#   - default (baseline)
#   - f16 alone (Phase 7)
#   - pooled+f16 (Phase 16, current best)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate
export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATASET="eval_medium"
DATA_DIR="/local-data/abumukh/data/gittables/$DATASET"
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="$DATA_DIR/queries/all.zst"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"
THREADS=(1 2 4 8 16 32 64)

run_sweep() {
    local label="$1"
    echo ""
    echo "[$label] sweep: ${THREADS[*]}"
    for t in "${THREADS[@]}"; do
        local log="$LOG_DIR/${DATASET}-${label}-native-t${t}.log"
        FAINDER_NUM_THREADS=$t run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
            --suppress-results --log-level INFO --log-file "$log" >/dev/null 2>&1
        local r=$(grep "Rust index-based query execution time" "$log" | tail -1 | grep -oP '[0-9]+\.[0-9]+')
        echo "  t=$t: ${r}s"
    done
}

echo "============================================================"
echo "STEP 1: default-native"
echo "============================================================"
maturin develop --release -q 2>&1 | tail -1
run_sweep "default"

echo ""
echo "============================================================"
echo "STEP 2: f16-native"
echo "============================================================"
maturin develop --release --features f16 -q 2>&1 | tail -1
run_sweep "f16"

echo ""
echo "============================================================"
echo "STEP 3: pooled-f16-native"
echo "============================================================"
maturin develop --release --features "pooled f16" -q 2>&1 | tail -1
run_sweep "pooled-f16"

# Restore default
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "============================================================"
echo "Summary — eval_medium with target-cpu=native"
echo "============================================================"
printf "%-8s %-14s %-14s %-14s %-12s\n" "Threads" "default(s)" "f16(s)" "pooled+f16(s)" "P+f16/Python"
for t in "${THREADS[@]}"; do
    d=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-default-native-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    f=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-f16-native-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    pf=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-pooled-f16-native-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    if [[ -n "$pf" ]]; then
        sp=$(python3 -c "print(f'{18.27 / $pf:.2f}x')")
    else
        sp="N/A"
    fi
    printf "%-8s %-14s %-14s %-14s %-12s\n" "t=$t" "${d:-N/A}" "${f:-N/A}" "${pf:-N/A}" "$sp"
done
