#!/usr/bin/env bash
# Fine-t experiments addressing Lennart's p7 + p6 + p8 PDF annotations.
#
# What's measured (all on c256_56gb, suppress, 5 reps):
#   1. f16 standalone — completely missing in bench.db
#      thread counts: 1, 8, 12, 14, 16, 18, 20, 24, 28, 32, 48, 64, 96
#   2. default at fine-t (fills gaps: 12, 14, 18, 20, 24, 28, 48)
#   3. default + bestofsuite at t=128 (already have t=192 for HT story)
#
# Total: ~115 measurements, ~55 min wall.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
DATASET="c256_56gb"
REPEATS=5
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

FIDX="$DATA_BASE/$DATASET/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

sweep () {
    local features="$1" build_tag="$2" label_suffix="$3" threads_csv="$4"
    echo
    echo "=========== build: ${build_tag} (features='${features:-default}') ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi
    for t in $threads_csv; do
        echo
        echo "  --- ${build_tag} t=$t ---"
        scripts/bench.py \
            --build "$build_tag" --sweep "$t" --repeats "$REPEATS" \
            --index "$FIDX" --queries "$QUERIES" \
            --label "lennart_${DATASET}_${label_suffix}" || echo "  [warn] failed"
    done
}

echo "============================================================"
echo " Lennart fine-t experiments — $(date -Iseconds)"
echo "============================================================"

# (1) f16 standalone, full thread range incl. fine-t around L3 transition
sweep "f16" "lennart_f16" "f16" "1 8 12 14 16 18 20 24 28 32 48 64 96"

# (2) default at fine-t gaps + t=48 (existing data has 1/8/16/32/64/96)
sweep "" "lennart_default_finet" "default_finet" "12 14 18 20 24 28 48"

# (3) default + bestofsuite at t=128 (we have t=192 already)
sweep "" "lennart_default_t128" "default_t128" "128"
sweep "pooled f16 simd pin-cores cluster-prefetch mimalloc" \
      "lennart_bestofsuite_t128" "bestofsuite_t128" "128"

echo
echo "============================================================"
echo " Lennart fine-t complete — $(date -Iseconds)"
echo "============================================================"
