#!/usr/bin/env bash
# Cluster-par ablation: nested Rayon parallelism inside queries that are
# already running in parallel.
#
# Default row-centric engine: par_iter() over queries, sequential clusters.
# cluster-par feature:        par_iter() over queries, par_iter() over clusters.
#
# Question: does giving Rayon more fine-grained tasks (10K queries × ~150 clusters
# = ~1.5M tasks vs just 10K) help work-stealing balance better, or does the
# additional task overhead exceed the win?
#
# 3 datasets × 6 thread counts × 5 reps = 90 runs at suppress, ~30 min total.
# Rows land with label='main_<size>_clusterpar_supp' so the report picks them up.

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
echo " Cluster-par ablation — $(date -Iseconds)"
echo "============================================================"

echo "  [build] cargo --release --features cluster-par"
maturin develop --release --features cluster-par -q 2>&1 | tail -1

for size in "${SIZES[@]}"; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] $fidx missing for $size"
        continue
    fi
    echo
    echo "============== $size — cluster-par (suppress) =============="
    FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
        --build "clusterpar" \
        --sweep "$SWEEP" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_clusterpar_supp" \
        || echo "  [warn] sweep failed (timeout or error) — continuing"
done

echo
echo "============================================================"
echo " Cluster-par ablation complete — $(date -Iseconds)"
echo "============================================================"
echo "Re-run scripts/main_axes_report.py to pick up new cells."
