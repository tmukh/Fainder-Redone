#!/usr/bin/env bash
# Resume of run_ood_structural_validation.sh, picking up at ood_morsel_K128
# t=64 after the original sweep was killed at 141/270 cells.
#
# Skips: f16, aos, bs_packed_ids, bs_qbatch_K128, morsel_K128 (t<=32, all 5 reps)
# Does:  morsel_K128 t=64..96, local_ids, local_ids_bench, simd, NUMA variants.

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

sweep_build () {
    local features="$1" build_tag="$2" label_suffix="$3"
    local extra_env="${4:-}" threads_csv="${5:-1 8 16 32 64 96}"
    echo
    echo "=========== build: ${build_tag} (features='${features:-default}') ==========="
    maturin develop --release --features "$features" -q 2>&1 | tail -1
    for t in $threads_csv; do
        echo
        echo "  --- ${build_tag} t=$t ${extra_env} ---"
        if [[ -n "$extra_env" ]]; then
            eval "$extra_env" scripts/bench.py \
                --build "$build_tag" --sweep "$t" --repeats "$REPEATS" \
                --index "$FIDX" --queries "$QUERIES" \
                --label "ood_${DATASET}_${label_suffix}" || true
        else
            scripts/bench.py \
                --build "$build_tag" --sweep "$t" --repeats "$REPEATS" \
                --index "$FIDX" --queries "$QUERIES" \
                --label "ood_${DATASET}_${label_suffix}" || true
        fi
    done
}

sweep_prefix () {
    local prefix="$1" build_tag="$2" label_suffix="$3" threads_csv="$4"
    echo
    echo "=========== prefix: '${prefix}' (reuse existing build) ==========="
    for t in $threads_csv; do
        echo
        echo "  --- ${build_tag} t=$t prefix='${prefix}' ---"
        FAINDER_BENCH_PREFIX="$prefix" scripts/bench.py \
            --build "$build_tag" --sweep "$t" --repeats "$REPEATS" \
            --index "$FIDX" --queries "$QUERIES" \
            --label "ood_${DATASET}_${label_suffix}" || true
    done
}

echo "============================================================"
echo " RESUME structural sweep — $DATASET, $(date -Iseconds)"
echo "============================================================"

# Finish morsel_K128 at t=64 (orphan rep is in db; 5 fresh reps over-replicate,
# analyser uses median so this is fine) and t=96.
sweep_build "morsel query-batch" "ood_morsel_K128" "morsel_K128" \
            "FAINDER_QUERY_BATCH=128" "64 96"

# §3.11 builds.
sweep_build "local-ids" "ood_local_ids" "local_ids"
sweep_build "local-ids-bench" "ood_local_ids_bench" "local_ids_bench"

# Ceiling (i) null spot-check.
sweep_build "simd" "ood_simd" "simd"

# Ceiling (iv) NUMA placement: rebuild packed-ids so the binary matches.
echo
echo "=========== group (D) — rebuild packed-ids ==========="
maturin develop --release --features packed-ids -q 2>&1 | tail -1

sweep_prefix "numactl --cpunodebind=0 --membind=0" \
             "ood_packed_ids_single_socket" "packed_ids_single_socket" "32 48"
sweep_prefix "numactl --interleave=0,1" \
             "ood_packed_ids_interleave" "packed_ids_interleave" "32 48 64 96"

echo
echo "============================================================"
echo " RESUME complete — $(date -Iseconds)"
echo "============================================================"
