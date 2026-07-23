#!/usr/bin/env bash
# Python-baseline suppress-mode fill-in for §4.15 apples-to-apples comparison.
#
# Rust ablations in §4.5-§4.14 all use suppress mode (_supp labels). The Python
# baseline in bench.db is with-results only (_with), so the "search-phase
# speedup vs Python" number currently uses Rust suppress vs Python with-results,
# which attributes Python's result-boxing cost to the Rust engine's win.
#
# This sweep produces the missing Python suppress rows so §4.15 can report
# both suppress/suppress (search-phase) and with-results/with-results
# (end-to-end) as clean apples-to-apples ratios.
#
# Python is GIL-bound and wall-flat across t (verified on c256_10gb: t=1, 16,
# 96 all measure ~600s in with-results). One anchor t=16 per dataset is enough.
#
# Time budget (all t=16, 5 reps):
#   c256_10gb  ~500-600 s/rep × 5 ≈  50-60 min
#   c256_30gb ~1700-1900 s/rep × 5 ≈  2.5-2.8 h
#   c256_56gb  (subsample 1K, seed 42) ~900-1050 s/rep × 5 ≈  75-90 min
#   Total:                                                   ~4.5 h
#
# Timeout per rep: 5h (well above worst-case).
#
# Labels written to bench.db:
#   main_10gb_python_supp
#   main_30gb_python_supp
#   main_56gb_python_supp_subsample1k
# (§4.15 code will multiply the 56gb subsample wall by 10 for the speedup ratio.)

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
REPEATS=5
TIMEOUT_S=18000  # 5 h per rep

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

run_python_supp () {
    local size="$1"
    local t="$2"
    local label="$3"
    local queries_path="$4"
    local fidx="$DATA_BASE/c256_${size}/indices/best_config_rebinning.fidx"

    echo
    echo "======================================================================"
    echo " c256_${size}  python suppress  t=${t}  x${REPEATS} reps  $(date -Iseconds)"
    echo " label=${label}"
    echo " queries=${queries_path}"
    echo "======================================================================"

    if [[ ! -d "$fidx" ]]; then
        echo "  [skip] fidx missing at $fidx"
        return 1
    fi
    if [[ ! -f "$queries_path" ]]; then
        echo "  [skip] queries missing at $queries_path"
        return 1
    fi

    FAINDER_NO_RUST=1 FAINDER_SUPPRESS_RESULTS=1 \
        scripts/bench.py \
        --build "python" \
        --sweep "$t" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries_path" \
        --label "$label" \
        || echo "  [warn] sweep failed or timed out - continuing"
}

echo "############################################################"
echo " Python suppress-mode backfill  -  $(date -Iseconds)"
echo " REPO=$REPO"
echo " REPEATS=$REPEATS  TIMEOUT_S=$TIMEOUT_S"
echo "############################################################"

# Shortest first so we get one row into bench.db quickly.
run_python_supp "10gb" 16 "main_10gb_python_supp" \
    "$DATA_BASE/c256_10gb/queries/all.zst"

# Subsample for 56gb (matches existing with-results subsample methodology).
run_python_supp "56gb" 16 "main_56gb_python_supp_subsample1k" \
    "$DATA_BASE/c256_56gb/queries/subsample_1k_seed42.zst"

# Longest last.
run_python_supp "30gb" 16 "main_30gb_python_supp" \
    "$DATA_BASE/c256_30gb/queries/all.zst"

echo
echo "############################################################"
echo " Suppress backfill complete - $(date -Iseconds)"
echo "############################################################"

# Marker file for external completion detection (mirrors backfill/subsample pattern)
touch "$REPO/logs/python_suppress_backfill.done"
