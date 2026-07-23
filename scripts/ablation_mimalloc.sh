#!/bin/bash
# Re-measure mimalloc on top of the headline pooled+f16+pin-cores stack with
# proper min-of-3 methodology. The original mimalloc results in Table 16 were
# generated ad-hoc and never saved to logs/, so the thesis abstract headline
# (8.16x) is currently unverifiable. This script fixes that.
#
# Two builds:
#   A. pooled+f16+pin-cores            (the no-mimalloc baseline)
#   B. pooled+f16+pin-cores+mimalloc   (the headline configuration)
#
# Threads:    {1, 8, 16, 32, 64}
# Repeats:    3 per (build, thread) -> log files named -r1.log, -r2.log, -r3.log
# Reported:   min of 3
#
# Excludes cluster-prefetch deliberately: the audit (2026-04-27) confirmed it
# is null/negative at t=16, so the headline stack should not depend on it.

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
THREADS=(1 8 16 32 64)
REPEATS=3

run_sweep() {
    local label="$1"
    echo ""
    echo "[$label] sweep: ${THREADS[*]}, $REPEATS repeats each"
    for t in "${THREADS[@]}"; do
        for r in $(seq 1 $REPEATS); do
            local log="$LOG_DIR/${DATASET}-${label}-t${t}-r${r}.log"
            FAINDER_NUM_THREADS=$t run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
                --suppress-results --log-level INFO --log-file "$log" >/dev/null 2>&1
        done
        # Compute min across repeats
        local min_t=$(for r in $(seq 1 $REPEATS); do
            grep "Rust index-based query execution time" \
                "$LOG_DIR/${DATASET}-${label}-t${t}-r${r}.log" 2>/dev/null \
                | tail -1 | grep -oP '[0-9]+\.[0-9]+'
        done | sort -n | head -1)
        echo "  t=$t: min=${min_t}s"
    done
}

echo "============================================================"
echo "Build A: pooled+f16+pin-cores (no mimalloc)"
echo "============================================================"
maturin develop --release --features "pooled f16 pin-cores" -q 2>&1 | tail -1
run_sweep "pooled-f16-pin-nomimalloc"

echo ""
echo "============================================================"
echo "Build B: pooled+f16+pin-cores+mimalloc"
echo "============================================================"
maturin develop --release --features "pooled f16 pin-cores mimalloc" -q 2>&1 | tail -1
run_sweep "pooled-f16-pin-mimalloc"

# Restore default
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "============================================================"
echo "Summary: eval_medium, min-of-3, headline = Python(18.27s) / min"
echo "============================================================"
printf "%-8s %-14s %-14s %-10s\n" "Threads" "no-mimalloc(s)" "mimalloc(s)" "delta"
for t in "${THREADS[@]}"; do
    nm=$(for r in $(seq 1 $REPEATS); do
        grep "Rust index-based query execution time" \
            "$LOG_DIR/${DATASET}-pooled-f16-pin-nomimalloc-t${t}-r${r}.log" 2>/dev/null \
            | tail -1 | grep -oP '[0-9]+\.[0-9]+'
    done | sort -n | head -1)
    mm=$(for r in $(seq 1 $REPEATS); do
        grep "Rust index-based query execution time" \
            "$LOG_DIR/${DATASET}-pooled-f16-pin-mimalloc-t${t}-r${r}.log" 2>/dev/null \
            | tail -1 | grep -oP '[0-9]+\.[0-9]+'
    done | sort -n | head -1)
    if [[ -n "$nm" && -n "$mm" ]]; then
        d=$(python3 -c "print(f'{($nm - $mm) / $nm * 100:+.1f}%')")
    else
        d="N/A"
    fi
    printf "%-8s %-14s %-14s %-10s\n" "t=$t" "${nm:-N/A}" "${mm:-N/A}" "$d"
done

echo ""
echo "Headline (vs Python 18.27s):"
for t in "${THREADS[@]}"; do
    nm=$(for r in $(seq 1 $REPEATS); do
        grep "Rust index-based query execution time" \
            "$LOG_DIR/${DATASET}-pooled-f16-pin-nomimalloc-t${t}-r${r}.log" 2>/dev/null \
            | tail -1 | grep -oP '[0-9]+\.[0-9]+'
    done | sort -n | head -1)
    mm=$(for r in $(seq 1 $REPEATS); do
        grep "Rust index-based query execution time" \
            "$LOG_DIR/${DATASET}-pooled-f16-pin-mimalloc-t${t}-r${r}.log" 2>/dev/null \
            | tail -1 | grep -oP '[0-9]+\.[0-9]+'
    done | sort -n | head -1)
    if [[ -n "$nm" && -n "$mm" ]]; then
        sp_nm=$(python3 -c "print(f'{18.27 / $nm:.2f}x')")
        sp_mm=$(python3 -c "print(f'{18.27 / $mm:.2f}x')")
        echo "  t=$t: no-mimalloc=$sp_nm, mimalloc=$sp_mm"
    fi
done
