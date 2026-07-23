#!/usr/bin/env bash
# Fills the two Python-baseline gaps in bench.db needed for the
# experiment_walkthrough §3 plot:
#   - c256_30gb: currently 3 reps at t=16 only; add 5 more reps at t=16
#   - c256_56gb: currently zero rows; add 5 reps at t=16
#
# Python is GIL-bound → wall is flat across t (verified on c256_10gb where
# t=1, 16, 96 all measure ~600s). One anchor t is sufficient to compute
# the plot's Rust-vs-Python speedup at every Rust t.
#
# Time budget:
#   c256_30gb  t=16  ~1900 s/rep × 5 =  ~2.6 h
#   c256_56gb  t=16  ~9300 s/rep × 5 = ~12.9 h
#   Total:                            ~15.5 h  (overnight)
#
# Timeout per rep: 5 h (generous for c256_56gb worst case).

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
REPEATS=5
TIMEOUT_S=18000  # 5 hours per rep — well above c256_56gb worst case

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

run_python () {
    local size="$1"
    local t="$2"
    local fidx="$DATA_BASE/c256_${size}/indices/best_config_rebinning.fidx"
    local queries="$DATA_BASE/c256_${size}/queries/all.zst"

    echo
    echo "======================================================================"
    echo " c256_${size}  python  t=${t}  x${REPEATS} reps  $(date -Iseconds)"
    echo "======================================================================"

    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] fidx missing at $fidx"
        return 1
    fi

    FAINDER_NO_RUST=1 FAINDER_SUPPRESS_RESULTS=0 \
        scripts/bench.py \
        --build "python" \
        --sweep "$t" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "main_${size}_python_with" \
        || echo "  [warn] sweep failed or timed out — continuing"
}

echo "############################################################"
echo " Python baseline backfill  —  $(date -Iseconds)"
echo " REPO=$REPO"
echo " REPEATS=$REPEATS  TIMEOUT_S=$TIMEOUT_S"
echo "############################################################"

# Start with the shorter one so we get one row into bench.db quickly.
run_python "30gb" 16
run_python "56gb" 16

echo
echo "############################################################"
echo " Backfill complete — $(date -Iseconds)"
echo "############################################################"

# Marker file so we can detect completion externally without parsing tmux buffer
touch "$REPO/logs/python_backfill.done"
