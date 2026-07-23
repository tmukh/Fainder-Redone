#!/usr/bin/env bash
# OOD dispatch validation for c1024_56gb (Phase 2 stretch experiment).
#
# Runs the dispatch-relevant build set at threads [1,8,16,32,64,96],
# 5 reps each, on the c1024_56gb fidx. The closing analysis compares
# the actually-best build per thread count to the dispatch policy's
# prediction (fainder/execution/dispatch.py).
#
# Outcomes:
#   - 6/6 cells match (or within 5%) → dispatch generalises to a
#     sparser-cluster regime; Claim 2 robust.
#   - <6/6 → 4th regime cell identified; document the boundary the
#     dispatch policy needs to learn.
#
# Build set (matches dispatch.py's emissions):
#   1. default                                — control
#   2. bestofsuite                             — t<=32 cells, t>96 cells
#   3. packed-ids                              — big-data t=64 cell
#   4. query-batch (K=64 for t=1, K=128 else)  — big-data t=1 + t>=65 cells
#
# Build cost: 4 cargo rebuilds × ~30s = ~2 min.
# Run cost:   5 × 6 × 5 = 150 wall_s samples × ~25-30s = ~1.5-2 hours.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
DATASET="c1024_56gb"
REPEATS=5
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

FIDX="$DATA_BASE/$DATASET/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

if [[ ! -d "$FIDX" ]]; then
    echo "ERROR: $FIDX does not exist (build c1024_56gb first via scripts/build_dataset_ood.sh 1024)" >&2
    exit 1
fi

echo "============================================================"
echo " OOD dispatch validation — $DATASET, $(date -Iseconds)"
echo " threads: 1, 8, 16, 32, 64, 96"
echo " reps:    $REPEATS each"
echo " index:   $FIDX"
echo " queries: $QUERIES"
echo "============================================================"

# Helper: rebuild a cargo feature set + sweep its 6 thread counts.
sweep_build () {
    local features="$1"
    local build_tag="$2"
    local label_suffix="$3"
    local extra_env="${4:-}"   # optional env var assignments

    echo
    echo "=========== build: ${build_tag} (features='${features:-default}') ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi

    for t in 1 8 16 32 64 96; do
        echo
        echo "  --- ${build_tag} t=$t ${extra_env} ---"
        if [[ -n "$extra_env" ]]; then
            eval "$extra_env" scripts/bench.py \
                --build "$build_tag" \
                --sweep "$t" \
                --repeats "$REPEATS" \
                --index "$FIDX" \
                --queries "$QUERIES" \
                --label "ood_${DATASET}_${label_suffix}" \
                || echo "  [warn] ${build_tag} t=$t failed"
        else
            scripts/bench.py \
                --build "$build_tag" \
                --sweep "$t" \
                --repeats "$REPEATS" \
                --index "$FIDX" \
                --queries "$QUERIES" \
                --label "ood_${DATASET}_${label_suffix}" \
                || echo "  [warn] ${build_tag} t=$t failed"
        fi
    done
}

# 1. default — control baseline.
sweep_build "" "ood_default" "default"

# 2. bestofsuite — dispatch's recommendation at t<=32, plus general fallback.
sweep_build "pooled f16 simd pin-cores cluster-prefetch mimalloc" \
            "ood_bestofsuite" \
            "bestofsuite"

# 3. packed-ids — dispatch's recommendation at big-data t=64.
sweep_build "packed-ids" "ood_packed_ids" "packed_ids"

# 4. query-batch — dispatch's recommendation at t=1 (K=64) and t>=65 (K=128).
#    Run both K values across all t for a complete picture.
sweep_build "query-batch" "ood_qbatch_K64"  "qbatch_K64"  "FAINDER_QUERY_BATCH=64"
sweep_build "query-batch" "ood_qbatch_K128" "qbatch_K128" "FAINDER_QUERY_BATCH=128"

echo
echo "============================================================"
echo " OOD validation sweep complete — $(date -Iseconds)"
echo " Next: scripts/analyse_ood_dispatch.py reads bench.db and"
echo "       compares actually-best to dispatch.py prediction."
echo "============================================================"
