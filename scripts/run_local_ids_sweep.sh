#!/usr/bin/env bash
# Per-cluster reindexing sweep — measure local-ids vs local-ids-bench
# vs packed-ids vs default × {datasets} × {threads} × 5 reps. Two
# follow-up sweeps are in scope:
#   (a) the four-way comparison at default-engine row-centric (this script)
#   (b) local-ids composed onto query-batch K=128 — the qbatch-locality
#       prediction registered in §3.11. Run with FAINDER_QUERY_BATCH=128
#       and --features 'local-ids query-batch'.
#
# Rows land with label='main_<size>_local_ids_supp', etc.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZES=("${@:-10gb 30gb 56gb}")
SWEEP="1,8,16,32,64,96"
REPEATS=5
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

echo "============================================================"
echo " local-ids sweep — $(date -Iseconds) — sizes: ${SIZES[*]}, threads: $SWEEP"
echo "============================================================"

run_one_build () {
    local features="$1"
    local label_suffix="$2"
    local build_tag="$3"
    echo
    echo "=========== build: --features '$features' (tag=$build_tag) ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi
    for size in "${SIZES[@]}"; do
        fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
        queries="$DATA_BASE/c256_$size/queries/all.zst"
        if [[ ! -d "$fidx" ]]; then
            echo "  [skip] $fidx missing for $size"
            continue
        fi
        echo
        echo "  --- $size ---"
        scripts/bench.py \
            --build "$build_tag" \
            --sweep "$SWEEP" \
            --repeats "$REPEATS" \
            --index "$fidx" \
            --queries "$queries" \
            --label "main_${size}_${label_suffix}_supp" \
            || echo "  [warn] sweep failed (timeout or error) — continuing"
    done
}

# Default-engine arm: row-centric (par_iter over queries). This is where
# the qbatch-locality prediction (§3.11) predicts NEGATIVE for option 1
# (lookup table flushes between every (q, c+1) cluster transition).
# default + packed-ids are already in bench.db; only running the new
# variants here.
run_one_build "local-ids"            "local_ids"           "local_ids"
run_one_build "local-ids-bench"      "local_ids_bench"     "local_ids_bench"
run_one_build "local-ids-noalloc"    "local_ids_noalloc"   "local_ids_noalloc"

# qbatch-K=128 composition arm: tests the prediction that option 1 wins
# in qbatch+big+high-t (cooperative caching keeps the lookup table L1-hot
# across the K-batch). Constrain to the regime cells where qbatch K=128
# is competitive on the existing data: 56gb t=64/96 + 30gb t=64/96.
run_one_build_qb128 () {
    local features="$1"
    local label_suffix="$2"
    local build_tag="$3"
    echo
    echo "=========== build: --features '$features' (qbatch K=128, tag=$build_tag) ==========="
    maturin develop --release --features "$features" -q 2>&1 | tail -1
    for size in "${SIZES[@]}"; do
        # Skip 10gb for qbatch composition — qbatch loses on small data per §3.9.4
        case "$size" in
            10gb) echo "  [skip] $size for qbatch composition"; continue ;;
        esac
        fidx="$DATA_BASE/c256_$size/indices/best_config_rebinning.fidx"
        queries="$DATA_BASE/c256_$size/queries/all.zst"
        [[ -d "$fidx" ]] || { echo "  [skip] $fidx missing"; continue; }
        echo
        echo "  --- $size (qbatch K=128) ---"
        FAINDER_QUERY_BATCH=128 scripts/bench.py \
            --build "$build_tag" \
            --sweep "64,96" \
            --repeats "$REPEATS" \
            --index "$fidx" \
            --queries "$queries" \
            --label "main_${size}_${label_suffix}_supp" \
            || echo "  [warn] sweep failed (timeout or error) — continuing"
    done
}

run_one_build_qb128 "query-batch local-ids"          "qb128_local_ids"        "qb128_local_ids"
run_one_build_qb128 "query-batch local-ids-bench"    "qb128_local_ids_bench"  "qb128_local_ids_bench"

echo
echo "============================================================"
echo " local-ids sweep complete — $(date -Iseconds)"
echo "============================================================"
