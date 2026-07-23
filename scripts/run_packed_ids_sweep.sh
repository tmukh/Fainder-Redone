#!/usr/bin/env bash
# packed-ids benchmark sweep — apples-to-apples vs default at suppress.
# Build: --features packed-ids (per-cluster bit-packed IDs, width = ceil(log2(max_id+1)))
# 3 datasets × 6 threads × 5 reps = 90 runs.
# Rows land with label='main_<size>_packed_ids_supp' so reports can pick them up.

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
echo " packed-ids benchmark sweep — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features packed-ids"
maturin develop --release --features packed-ids -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — packed_ids (suppress) =============="
    scripts/bench.py \
        --build "packed_ids" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_packed_ids_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " packed-ids sweep complete — $(date -Iseconds)"
echo "============================================================"
