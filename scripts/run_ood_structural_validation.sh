#!/usr/bin/env bash
# Option B structural-validation sweep at c1024_56gb.
#
# Phase 2 (§3.14) only validated the dispatch policy at the OOD point.
# This sweep validates the structural claims — the four ceilings and the
# five negative-composability instances — at the sparser-cluster regime.
#
# Groups:
#   (A) Ceiling (ii) shared L3: f16 (footprint shrinker) vs aos (footprint
#       expander). Tests whether L3-pressure-mediated wins/losses reproduce.
#   (B) Neg-comp cross-density: all 5 instances re-run against the
#       composed baseline at c1024 to test cross-axis × cross-density.
#       §3.7.6 (bestofsuite + packed-ids), §3.9.7 (bestofsuite + qbatch),
#       §3.10 (morsel + qbatch K=128), §3.11 (local-ids + local-ids-bench).
#   (C) Ceiling (i) null: simd spot-check on latency-isn't-binding.
#   (D) Ceiling (iv) cross-socket UPI at c1024 using the existing packed-ids
#       build with numactl prefixes (no cargo rebuild needed).
#
# Build cost: 8 cargo rebuilds × ~30s = ~4 min.
# Sweep cost: ~260 measurements × ~25-30s = ~2 hours wall.

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
    echo "ERROR: $FIDX not found" >&2
    exit 1
fi

echo "============================================================"
echo " OOD structural validation — $DATASET, $(date -Iseconds)"
echo " (Phase 4 — does the structural finding reproduce at K=1024?)"
echo "============================================================"

# Helper: build + sweep all 6 standard thread counts.
sweep_build () {
    local features="$1"
    local build_tag="$2"
    local label_suffix="$3"
    local extra_env="${4:-}"
    local threads_csv="${5:-1 8 16 32 64 96}"

    echo
    echo "=========== build: ${build_tag} (features='${features:-default}') ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi

    for t in $threads_csv; do
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

# Helper: rerun an existing built binary with a numactl prefix (no rebuild).
sweep_prefix () {
    local prefix="$1"
    local build_tag="$2"
    local label_suffix="$3"
    local threads_csv="$4"

    echo
    echo "=========== prefix: '${prefix}' (reuse existing build) ==========="
    for t in $threads_csv; do
        echo
        echo "  --- ${build_tag} t=$t prefix='${prefix}' ---"
        FAINDER_BENCH_PREFIX="$prefix" scripts/bench.py \
            --build "$build_tag" \
            --sweep "$t" \
            --repeats "$REPEATS" \
            --index "$FIDX" \
            --queries "$QUERIES" \
            --label "ood_${DATASET}_${label_suffix}" \
            || echo "  [warn] ${build_tag} t=$t failed"
    done
}

# ==============================================================
# Group (A) — Ceiling (ii) shared L3
# ==============================================================
echo
echo "============ GROUP (A): ceiling (ii) shared L3 ============"
sweep_build "f16" "ood_f16" "f16"
sweep_build "aos" "ood_aos" "aos"

# ==============================================================
# Group (B) — Negative-composability cross-density
# ==============================================================
echo
echo "============ GROUP (B): neg-composability cross-density ============"

# §3.7.6: bestofsuite + packed-ids
sweep_build "pooled f16 simd pin-cores cluster-prefetch mimalloc packed-ids" \
            "ood_bs_packed_ids" "bs_packed_ids"

# §3.9.7: bestofsuite + query-batch (K=128 chosen as the dispatch t=96 cell choice)
sweep_build "pooled f16 simd pin-cores cluster-prefetch mimalloc query-batch" \
            "ood_bs_qbatch_K128" "bs_qbatch_K128" \
            "FAINDER_QUERY_BATCH=128"

# §3.10: morsel; compose vs existing ood_qbatch_K128 data.
# morsel uses query-batch under the hood; FAINDER_QUERY_BATCH still active.
sweep_build "morsel query-batch" \
            "ood_morsel_K128" "morsel_K128" \
            "FAINDER_QUERY_BATCH=128"

# §3.11: local-ids (with lookup) and local-ids-bench (verbatim local IDs).
# These compose vs existing ood_packed_ids at multi-thread.
sweep_build "local-ids" "ood_local_ids" "local_ids"
sweep_build "local-ids-bench" "ood_local_ids_bench" "local_ids_bench"

# ==============================================================
# Group (C) — Ceiling (i) null spot-check
# ==============================================================
echo
echo "============ GROUP (C): ceiling (i) latency null ============"
sweep_build "simd" "ood_simd" "simd"

# ==============================================================
# Group (D) — Ceiling (iv) cross-socket UPI (reuse packed-ids)
# Rebuild packed-ids first to make sure it's the active binary, then run
# with the three numactl placements at t=32 and t=48.
# ==============================================================
echo
echo "============ GROUP (D): ceiling (iv) NUMA placement ============"

echo
echo "[D-prep] rebuild packed-ids so the binary matches the existing label..."
maturin develop --release --features packed-ids -q 2>&1 | tail -1

sweep_prefix "numactl --cpunodebind=0 --membind=0" \
             "ood_packed_ids_single_socket" "packed_ids_single_socket" \
             "32 48"

sweep_prefix "numactl --interleave=0,1" \
             "ood_packed_ids_interleave" "packed_ids_interleave" \
             "32 48 64 96"

echo
echo "============================================================"
echo " OOD structural validation complete — $(date -Iseconds)"
echo " Next: scripts/analyse_ood_structural.py reads bench.db"
echo "       and reports per-ceiling and per-neg-comp reproduction."
echo "============================================================"
