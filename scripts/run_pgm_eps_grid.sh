#!/usr/bin/env bash
# PGM ε-grid mini-sweep — c256_10gb only, full thread sweep.
#
# Tests epsilon ∈ {16, 32, 64, 128} to find the wall-time elbow.
# 4 ε × 6 thread counts × 5 reps = 120 runs at suppress, ~15 min.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
INDEX="/local-data/abumukh/data/gittables/c256_10gb/indices/best_config_rebinning.fidx"
QUERIES="/local-data/abumukh/data/gittables/c256_10gb/queries/all.zst"
SWEEP="1,8,16,32,64,96"
REPEATS=5

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S=3600

echo "============================================================"
echo " PGM ε-grid mini-sweep on c256_10gb — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features pgm"
maturin develop --release --features pgm -q 2>&1 | tail -1

for EPS in 16 32 64 128; do
    echo
    echo "============== c256_10gb — pgm ε=$EPS (suppress) =============="
    FAINDER_PGM_EPSILON="$EPS" FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
        --build "pgm_eps$EPS" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$INDEX" \
        --queries "$QUERIES" \
        --label "main_10gb_pgm_eps${EPS}_supp" \
        || echo "  [warn] sweep failed — continuing"
done

echo
echo "============================================================"
echo " ε-grid sweep complete — $(date -Iseconds)"
echo "============================================================"
