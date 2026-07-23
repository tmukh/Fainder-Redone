#!/usr/bin/env bash
# PGM benchmark sweep — apples-to-apples against default at suppress.
#
# Build: --features pgm (ε=32 hardcoded in src/index.rs)
# 3 datasets × 6 threads × 5 reps = 90 runs, ~30 min.
# Rows land with label='main_<size>_pgm_supp' so main_axes_report.py picks them up.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SWEEP="1,8,16,32,64,96"
REPEATS=5
TIMEOUT_S=3600
SIZES=(10gb 30gb 56gb)

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

echo "============================================================"
echo " PGM benchmark sweep — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features pgm"
maturin develop --release --features pgm -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — pgm (suppress) =============="
    FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
        --build "pgm" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_pgm_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " PGM benchmark sweep complete — $(date -Iseconds)"
echo "============================================================"
