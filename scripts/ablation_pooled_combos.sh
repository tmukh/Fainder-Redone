#!/bin/bash
# Pooled output buffer compound experiments:
#   - pooled + f16   (does the pooled win amplify the f16 win?)
#   - pooled + kary  (does pooled help when search algorithm is also varied?)
#   - dev_small      (does pooled win at small scale too?)
#
# Usage:
#   bash scripts/ablation_pooled_combos.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate
export OPENBLAS_NUM_THREADS=64
export NUMEXPR_NUM_THREADS=64

DATA_BASE="/local-data/abumukh/data/gittables"
LOG_DIR="logs/ablation"
mkdir -p "$LOG_DIR"
THREADS=(1 2 4 8 16 32 64)

run_sweep() {
    local label="$1"; local dataset="$2"
    local index="$3"; local queries="$4"
    echo ""
    echo "[$dataset/$label] sweep: ${THREADS[*]}"
    for t in "${THREADS[@]}"; do
        local log="$LOG_DIR/${dataset}-${label}-t${t}.log"
        echo "  t=$t -> $log"
        FAINDER_NUM_THREADS=$t run-queries -i "$index" -t index -q "$queries" -m recall \
            --suppress-results --log-level INFO --log-file "$log" \
            && echo "    OK" || echo "    FAILED"
    done
}

EM_INDEX="$DATA_BASE/eval_medium/indices/best_config_rebinning.zst"
EM_Q="$DATA_BASE/eval_medium/queries/all.zst"
DS_INDEX="/home/abumukh-ldap/fainder-redone/data/dev_small/indices/best_config_rebinning.zst"
DS_Q="$DATA_BASE/dev_small/queries/all.zst"

echo "============================================================"
echo "STEP A: pooled+f16 on eval_medium"
echo "============================================================"
maturin develop --release --features "pooled f16" -q 2>&1 | tail -1
run_sweep "pooled-f16" "eval_medium" "$EM_INDEX" "$EM_Q"

echo ""
echo "============================================================"
echo "STEP B: pooled+kary on eval_medium"
echo "============================================================"
maturin develop --release --features "pooled kary" -q 2>&1 | tail -1
run_sweep "pooled-kary" "eval_medium" "$EM_INDEX" "$EM_Q"

echo ""
echo "============================================================"
echo "STEP C: pooled on dev_small"
echo "============================================================"
maturin develop --release --features pooled -q 2>&1 | tail -1
run_sweep "pooled" "dev_small" "$DS_INDEX" "$DS_Q"

# Restore default
echo ""
echo "Restoring default build..."
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "============================================================"
echo "Summary: eval_medium pooled+f16 vs default"
echo "============================================================"
printf "%-8s %-14s %-14s %-14s %-10s\n" "Threads" "Default" "Pooled" "Pooled+f16" "P+f16/Def"
for t in "${THREADS[@]}"; do
    def_t=$(grep "Rust index-based query execution time" "$LOG_DIR/eval_medium-default-out-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    p_t=$(grep "Rust index-based query execution time" "$LOG_DIR/eval_medium-pooled-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    pf_t=$(grep "Rust index-based query execution time" "$LOG_DIR/eval_medium-pooled-f16-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    if [[ -n "$def_t" && -n "$pf_t" ]]; then
        speedup=$(python3 -c "print(f'{$def_t / $pf_t:.2f}x')")
    else
        speedup="N/A"
    fi
    printf "%-8s %-14s %-14s %-14s %-10s\n" "t=$t" "${def_t:-N/A}" "${p_t:-N/A}" "${pf_t:-N/A}" "$speedup"
done

echo ""
echo "============================================================"
echo "Summary: eval_medium pooled+kary"
echo "============================================================"
printf "%-8s %-14s %-14s\n" "Threads" "Pooled" "Pooled+kary"
for t in "${THREADS[@]}"; do
    p_t=$(grep "Rust index-based query execution time" "$LOG_DIR/eval_medium-pooled-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    pk_t=$(grep "Rust index-based query execution time" "$LOG_DIR/eval_medium-pooled-kary-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    printf "%-8s %-14s %-14s\n" "t=$t" "${p_t:-N/A}" "${pk_t:-N/A}"
done

echo ""
echo "============================================================"
echo "Summary: dev_small pooled"
echo "============================================================"
printf "%-8s %-14s\n" "Threads" "Pooled (s)"
for t in "${THREADS[@]}"; do
    p_t=$(grep "Rust index-based query execution time" "$LOG_DIR/dev_small-pooled-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    printf "%-8s %-14s\n" "t=$t" "${p_t:-N/A}"
done
