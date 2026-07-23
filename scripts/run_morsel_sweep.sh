#!/usr/bin/env bash
# Morsel-driven scheduler sweep — first run on c256_56gb at the regime where
# the work-fragmentation ceiling binds (t=32/64/96), to see if morsel beats
# query-batch K=128's 16.17s at t=96.
#
# Build: --features morsel.
# Rows land with label='main_<size>_morsel_supp'.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZES=("${@:-56gb}")  # default: 56gb only; pass extra args to extend (e.g. "10gb 30gb 56gb")
SWEEP="32,64,96"
REPEATS=5
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

echo "============================================================"
echo " morsel sweep — $(date -Iseconds) — sizes: ${SIZES[*]}, threads: $SWEEP"
echo "============================================================"

echo "  [build] cargo --release --features morsel"
maturin develop --release --features morsel -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — morsel (suppress) =============="
    scripts/bench.py \
        --build "morsel" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_morsel_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " morsel sweep complete — $(date -Iseconds)"
echo "============================================================"
