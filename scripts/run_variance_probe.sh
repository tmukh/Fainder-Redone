#!/usr/bin/env bash
# Variance probe — 10 back-to-back reps of qbatch K=128 t=96 on c256_56gb.
# Goal: distinguish thermal/DVFS (monotone clock degradation through the
# sweep) from system noise (clock bouncing).
set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="56gb"
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

echo "============================================================"
echo " variance probe — qbatch K=128 t=96 on c256_$SIZE — $(date -Iseconds)"
echo " 10 back-to-back reps, label=variance_probe_qb128_t96"
echo "============================================================"

echo "  [build] cargo --release --features query-batch"
maturin develop --release --features query-batch -q 2>&1 | tail -1

fidx="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
queries="$DATA_BASE/c256_$SIZE/queries/all.zst"

FAINDER_QUERY_BATCH=128 scripts/bench.py \
    --build "query_batch_k128" \
    --threads 96 \
    --repeats 10 \
    --index "$fidx" \
    --queries "$queries" \
    --label "variance_probe_qb128_t96" \
    || echo "  [warn] sweep failed (timeout or error) — continuing"

echo
echo "============================================================"
echo " probe complete — $(date -Iseconds)"
echo "============================================================"
