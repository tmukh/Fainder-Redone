#!/usr/bin/env bash
# query-batch full sweep — generalises the 56gb t=64/96 finding to 3 datasets.
# Build: --features query-batch (K=64 default, FAINDER_QUERY_BATCH unset)
# 3 datasets × 6 threads × 5 reps = 90 runs at suppress.
# Rows land with label='main_<size>_query_batch_supp'.

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
echo " query-batch K=64 sweep — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features query-batch"
maturin develop --release --features query-batch -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — query_batch (suppress, K=64) =============="
    scripts/bench.py \
        --build "query_batch" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_query_batch_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " query-batch sweep complete — $(date -Iseconds)"
echo "============================================================"
