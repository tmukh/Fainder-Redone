#!/usr/bin/env bash
# Column-centric campaign — invert the parallelism axis.
#
# Default row-centric: par_iter(queries), sequential clusters within each query.
# Column-centric:      par_iter(clusters), sequential queries within each cluster.
#
# Why it might win: column-centric keeps each cluster's column data resident
# in L2/L3 while the thread sweeps through all 10K queries against it. Default
# row-centric re-fetches each cluster's columns 10K times (once per query).
#
# Three builds:
#   col_default     — FAINDER_COLUMNAR=1, no Cargo features
#   col_horizsimd   — FAINDER_COLUMNAR=1 + horizontal-simd (16-query SIMD lockstep)
#   col_batchsearch — FAINDER_COLUMNAR=1 + batch-search (8-way interleaved)
#
# 3 builds × 3 datasets × 6 thread counts × 5 reps = 270 runs at suppress.
# ETA: ~30-45 min.

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
echo " Column-centric campaign — $(date -Iseconds)"
echo "============================================================"

run_phase() {
    local label="$1" features="$2"
    echo
    echo "============================================================"
    echo " BUILD: $label"
    echo "        features=\"$features\""
    echo "============================================================"
    if [[ -z "$features" ]]; then
        maturin develop --release -q 2>&1 | tail -1
    else
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    fi
    for size in "${SIZES[@]}"; do
        local fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
        local queries="$DATA_BASE/c256_$size/queries/all.zst"
        if [[ ! -d "$fidx" ]]; then
            echo "  [skip] $fidx missing for $size"
            continue
        fi
        echo
        echo "--- $size — $label (suppress) ---"
        FAINDER_COLUMNAR=1 FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
            --build "$label" \
            --sweep "$SWEEP" \
            --repeats "$REPEATS" \
            --index "$fidx" \
            --queries "$queries" \
            --label "main_${size}_${label}_supp" \
            || echo "  [warn] sweep failed (timeout or error) — continuing"
    done
}

run_phase "col_default"     ""
run_phase "col_horizsimd"   "horizontal-simd"
run_phase "col_batchsearch" "batch-search"

echo
echo "============================================================"
echo " Column-centric campaign complete — $(date -Iseconds)"
echo "============================================================"
