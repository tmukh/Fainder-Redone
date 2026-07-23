#!/usr/bin/env bash
# bestofsuite + packed-ids composition sweep — does the bandwidth attack
# compose with the existing positive composition?
#
# Build: --features "pooled f16 simd pin-cores cluster-prefetch mimalloc packed-ids"
# 3 datasets × 6 threads × 5 reps = 90 runs at suppress.
# Rows land with label='main_<size>_bestofsuite_packed_supp'.
#
# Mechanism question we want answered:
#   - f16 halves VALUES bandwidth in the search phase
#   - packed-ids reduces IDS bandwidth (~37%) in the emit phase
#   - They target orthogonal data structures, so should compose additively
#   - But pin-cores may already mask bandwidth saturation; if so, packed-ids
#     wins compress relative to bestofsuite-without-packed
#
# The packed/bestofsuite delta tells us whether the emit-stream bandwidth
# attack is independent of the search-phase bandwidth attack.

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
echo " bestofsuite + packed-ids composition sweep — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features 'pooled f16 simd pin-cores cluster-prefetch mimalloc packed-ids'"
maturin develop --release --features "pooled f16 simd pin-cores cluster-prefetch mimalloc packed-ids" -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — bestofsuite_packed (suppress) =============="
    scripts/bench.py \
        --build "bestofsuite_packed" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_bestofsuite_packed_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " bestofsuite_packed sweep complete — $(date -Iseconds)"
echo "============================================================"
