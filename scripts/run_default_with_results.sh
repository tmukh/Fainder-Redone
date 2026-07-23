#!/usr/bin/env bash
# Follow-on sweep #2: default Rust at with-results.
#
# Completes the 2×2 decomposition matrix:
#   default × suppress       (have, from main_axes)
#   default × with-results   (this sweep)
#   bestofsuite × suppress   (running in bestofsuite_followup)
#   bestofsuite × with-results (have, from main_axes)
#
# 3 datasets × 6 thread counts × 5 reps = 90 runs at with-results.
# With-results is slow (PyO3 boxing dominates), so this could take 1-2h.
# Rows land with label='main_<size>_default_with' so the report picks them up.

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
echo " Default with-results follow-on — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release  (default — no extra features)"
maturin develop --release -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — default (with-results) =============="
    FAINDER_SUPPRESS_RESULTS=0 scripts/bench.py \
        --build "default" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_default_with" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " Default-with-results follow-on complete — $(date -Iseconds)"
echo "============================================================"
