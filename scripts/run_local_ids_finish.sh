#!/usr/bin/env bash
# Three sequential phases to complete the §3.11 data collection:
#   1. Re-run killed qbatch+local-ids-bench cells.
#   2. Sweep local-ids-noalloc (default engine + qbatch K=128 composition).
#   3. Run mechanism probe (perf counters at 56gb t=32 across all 5 builds).
# Sequential to keep perf counter results uncontaminated.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

# ── Phase 1: fill the qb128_local_ids_bench gaps killed mid-run.
echo "============================================================"
echo " phase 1: re-fill killed qb128_local_ids_bench cells — $(date -Iseconds)"
echo "============================================================"
maturin develop --release --features 'query-batch local-ids-bench' -q 2>&1 | tail -1
for cell in "30gb 96" "56gb 64" "56gb 96"; do
    size="${cell% *}"; t="${cell#* }"
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    [[ -d "$fidx" ]] || continue
    echo
    echo "  --- $size t=$t ---"
    FAINDER_QUERY_BATCH=128 scripts/bench.py \
        --build "qb128_local_ids_bench" \
        --threads "$t" \
        --repeats 5 \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_qb128_local_ids_bench_supp" \
        || echo "  [warn] $size t=$t failed"
done

# ── Phase 2a: local-ids-noalloc on the default (row-centric) engine.
echo
echo "============================================================"
echo " phase 2a: local-ids-noalloc default-engine sweep — $(date -Iseconds)"
echo "============================================================"
maturin develop --release --features 'local-ids-noalloc' -q 2>&1 | tail -1
for size in 10gb 30gb 56gb; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    [[ -d "$fidx" ]] || continue
    echo
    echo "  --- $size ---"
    scripts/bench.py \
        --build "local_ids_noalloc" \
        --sweep "1,8,16,32,64,96" \
        --repeats 5 \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_local_ids_noalloc_supp" \
        || echo "  [warn] $size failed"
done

# ── Phase 2b: local-ids-noalloc + qbatch K=128 (only big-data + high-t cells).
echo
echo "============================================================"
echo " phase 2b: qb128 + local-ids-noalloc — $(date -Iseconds)"
echo "============================================================"
maturin develop --release --features 'query-batch local-ids-noalloc' -q 2>&1 | tail -1
for size in 30gb 56gb; do
    fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
    queries="$DATA_BASE/c256_$size/queries/all.zst"
    [[ -d "$fidx" ]] || continue
    echo
    echo "  --- $size (qb128) ---"
    FAINDER_QUERY_BATCH=128 scripts/bench.py \
        --build "qb128_local_ids_noalloc" \
        --sweep "64,96" \
        --repeats 5 \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_qb128_local_ids_noalloc_supp" \
        || echo "  [warn] $size failed"
done

# ── Phase 3: mechanism probe with perf counters.
echo
echo "============================================================"
echo " phase 3: mechanism probe — $(date -Iseconds)"
echo "============================================================"
scripts/probe_local_ids_mechanism.sh 2>&1 | tee /tmp/local_ids_mech_probe.log

echo
echo "============================================================"
echo " all phases complete — $(date -Iseconds)"
echo "============================================================"
