#!/usr/bin/env bash
# c256_56gb Python-baseline via 1K-query subsample (seed 42), scaled ×10.
#
# Why subsample: full 10K queries needs 8-12h/rep on c256_56gb Python; the
# first attempt hit the 5h timeout at 65% of queries with rate degradation
# (memory pressure from with-results dict accumulation).
#
# Subsample validation on c256_10gb: 1K wall × 10 = 681s vs actual 600s
# (13% overshoot). Same seed → same bias direction on c256_56gb.
#
# Time budget:
#   1K queries × ~1s/query × 15.5 (n_hists ratio 56gb vs 10gb) ≈ 1050 s/rep
#   5 reps ≈ 5250 s = ~90 min
# Timeout per rep: 2 h (2× budget for safety).
#
# NOTE: bench.py inserts the raw 1K wall_s into bench.db under label
# "main_56gb_python_with_subsample1k". Cell 8 will detect that label and
# multiply by 10 for the speedup ratio.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
DATASET="c256_56gb"
REPEATS=5
TIMEOUT_S=7200  # 2 h per rep

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

FIDX="$DATA_BASE/$DATASET/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/$DATASET/queries/subsample_1k_seed42.zst"

echo "############################################################"
echo " c256_56gb Python subsample sweep — $(date -Iseconds)"
echo " Queries: $QUERIES  (1000 sampled from 10000)"
echo " Reps: $REPEATS   Timeout: $TIMEOUT_S s per rep"
echo "############################################################"

if [[ ! -f "$QUERIES" ]]; then
    echo "  [error] subsample file missing: $QUERIES"
    exit 1
fi

FAINDER_NO_RUST=1 FAINDER_SUPPRESS_RESULTS=0 \
    scripts/bench.py \
    --build "python" \
    --sweep "16" \
    --repeats "$REPEATS" \
    --index "$FIDX" \
    --queries "$QUERIES" \
    --label "main_56gb_python_with_subsample1k"

echo
echo "############################################################"
echo " Subsample sweep complete — $(date -Iseconds)"
echo "############################################################"
touch "$REPO/logs/python_subsample_backfill.done"
