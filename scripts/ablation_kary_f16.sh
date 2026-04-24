#!/bin/bash
# Compound: does k-ary search stack with f16 precision?
# k-ary reduces LLC misses per search (shared-cache-pressure regime win);
# f16 halves per-thread footprint (shared-cache-pressure regime win).
# Both target t=16 — the question is whether they multiply or cannibalise.

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
echo "STEP 1: f16 alone (baseline for compound)"
echo "========================================"
maturin develop --release --features f16 -q 2>&1 | tail -1
run_sweep "f16-reb"

echo ""
echo "========================================"
echo "STEP 2: kary + f16"
echo "========================================"
maturin develop --release --features "kary f16" -q 2>&1 | tail -1
run_sweep "kary-f16"

# Restore default
echo ""
echo "Restoring default build..."
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "========================================"
echo "Compound Summary — ${DATASET}"
echo "(Binary f32 data from logs/ablation/${DATASET}-binary-tN.log)"
echo "========================================"
printf "%-8s %-14s %-14s %-14s\n" "Threads" "f16 (s)" "kary+f16 (s)" "Speedup"
for t in "${THREADS[@]}"; do
    f16_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-f16-reb-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    kf_t=$(grep "Rust index-based query execution time" "$LOG_DIR/${DATASET}-kary-f16-t${t}.log" 2>/dev/null | tail -1 | grep -oP '[0-9]+\.[0-9]+')
    if [[ -n "$f16_t" && -n "$kf_t" ]]; then
        speedup=$(python3 -c "print(f'{$f16_t / $kf_t:.2f}x')")
    else
        speedup="N/A"
    fi
    printf "%-8s %-14s %-14s %-14s\n" "t=$t" "${f16_t:-N/A}" "${kf_t:-N/A}" "$speedup"
done
