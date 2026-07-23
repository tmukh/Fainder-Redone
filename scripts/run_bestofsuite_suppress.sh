#!/usr/bin/env bash
# Follow-on sweep: bestofsuite at suppress-results.
#
# The main campaign (run_main_axes.sh) measures bestofsuite at with-results
# only, per Lennart's methodology split (ablations supp, end-to-end with).
# Cross-section ratios then mix regimes. This sweep adds the missing cell so
# we can report a clean "search-phase improvement of bestofsuite vs default".
#
# 3 datasets × 6 thread counts × 5 reps = 90 runs at suppress, ~30 min total.
# Rows land in logs/bench.db with label='main_<size>_bestofsuite_supp' so
# main_axes_report.py picks them up automatically.

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
echo " Bestofsuite-suppress follow-on — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features \"pooled f16 simd pin-cores cluster-prefetch mimalloc\""
maturin develop --release --features "pooled f16 simd pin-cores cluster-prefetch mimalloc" -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — bestofsuite (suppress) =============="
    FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
        --build "bestofsuite" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_bestofsuite_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " Bestofsuite-suppress follow-on complete — $(date -Iseconds)"
echo "============================================================"
echo "Re-run scripts/main_axes_report.py to pick up the new cells."
