#!/usr/bin/env bash
# Fine-t f16 rep upgrade: adds 5 more reps at each (t, build) cell
# to bring §5.3/§5.4 from 5 reps → 10 reps per cell.
#
# Rationale: current 5-rep 95% CI half-width is ~3.4%; peak point-estimate
# at t=18 was -10%. 10 reps drops CI to ~2% so the -10% would clear zero.
#
# Sweep:
#   default_finet + lennart_f16 at t ∈ {8, 12, 14, 16, 18, 20, 24, 28, 32}
#   +5 reps per (t, build) = 90 new measurements
#
# Time estimate (from bench.db median wall):
#   sum per rep-set = 6.3 min → 5 more rep-sets = ~32 min
#   + 2 cargo builds ~5 min
#   Total: ~35-40 min

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
DATASET="c256_56gb"
REPEATS=5           # +5 to bring current 5 → 10
TIMEOUT_S=1800

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

FIDX="$DATA_BASE/$DATASET/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/$DATASET/queries/all.zst"

FINE_T="8 12 14 16 18 20 24 28 32"

sweep () {
    local features="$1" build_tag="$2" label_suffix="$3"
    echo
    echo "=========== build: ${build_tag} (features='${features:-default}') ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi
    for t in $FINE_T; do
        echo
        echo "  --- ${build_tag} t=$t ---"
        scripts/bench.py \
            --build "$build_tag" --sweep "$t" --repeats "$REPEATS" \
            --index "$FIDX" --queries "$QUERIES" \
            --label "lennart_${DATASET}_${label_suffix}" || echo "  [warn] failed"
    done
}

echo "############################################################"
echo " Fine-t 10-rep upgrade — $(date -Iseconds)"
echo " Sweep t: $FINE_T"
echo " +${REPEATS} reps per (t, build) → target 10 reps/cell"
echo "############################################################"

# (1) default at fine-t — +5 reps
sweep "" "lennart_default_finet" "default_finet"

# (2) f16 standalone at fine-t — +5 reps
sweep "f16" "lennart_f16" "f16"

echo
echo "############################################################"
echo " 10-rep upgrade complete — $(date -Iseconds)"
echo "############################################################"

# Marker file
touch "$REPO/logs/finetune_10rep.done"
