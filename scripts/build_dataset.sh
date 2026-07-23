#!/usr/bin/env bash
# Build one of the three thesis datasets at 256 clusters.
#
# Usage:  scripts/build_dataset.sh {10gb|30gb|56gb}
#
# What it does:
#   10gb / 30gb : reuse existing histograms.zst (eval_10gb / eval_medium),
#                 re-cluster at 256, build rebinning index, convert to .fidx.
#   56gb        : extract histograms from /local-data/.../pq (1M+ Parquets),
#                 cluster at 256, build rebinning index, convert to .fidx.
#
# All output goes to /local-data/abumukh/data/gittables/c256_<size>/ — /home
# is at 100% disk so we cannot write big files there. Logs likewise go under
# /local-data so they don't clobber repo logs/.
#
# Idempotent: existing artefacts are skipped. Delete the output dir to redo.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 {10gb|30gb|56gb}" >&2
    exit 1
fi

SIZE="$1"
REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"

case "$SIZE" in
    10gb)
        SRC_HIST="$DATA_BASE/eval_10gb/histograms.zst"
        OUT_DIR="$DATA_BASE/c256_10gb"
        BUILD_HIST=0
        ;;
    30gb)
        SRC_HIST="$DATA_BASE/eval_medium/histograms.zst"
        OUT_DIR="$DATA_BASE/c256_30gb"
        BUILD_HIST=0
        ;;
    56gb)
        SRC_PQ="$DATA_BASE/pq"
        OUT_DIR="$DATA_BASE/c256_56gb"
        SRC_HIST="$OUT_DIR/histograms.zst"
        BUILD_HIST=1
        ;;
    *)
        echo "Unknown size: $SIZE (expected 10gb, 30gb, or 56gb)" >&2
        exit 1
        ;;
esac

# Same clustering hyperparameters across all three so dataset-size is the
# only varying axis. 256 = 2.7× the 96 physical cores. -b 25600 keeps the
# bin-density at ~100 bins/cluster (matches the eval_medium baseline of
# 5000 bins / 57 clusters from the paper).
N_CLUSTERS=256
BIN_BUDGET=25600
SEED=42

# 56gb is full corpus; the rebuilds for 10/30gb are CPU-light. Stagger the
# worker counts so all three can run concurrently on a 96-core box without
# fighting each other.
case "$SIZE" in
    10gb) WORKERS=32 ;;
    30gb) WORKERS=48 ;;
    56gb) WORKERS=96 ;;
esac

LOG_DIR="$OUT_DIR/build_logs"
mkdir -p "$OUT_DIR/indices" "$LOG_DIR"

cd "$REPO"
source venv/bin/activate

# OpenBLAS / MKL inside MiniBatchKMeans spawn BLAS threads on top of our
# Python workers. Without a cap, -w 96 × internal BLAS threads exceeds the
# precompiled OpenBLAS NUM_THREADS limit and segfaults during cluster step.
# 8 BLAS threads per worker × 32 workers ≈ 256 total — fits the OpenBLAS
# default of NUM_THREADS=512 with headroom.
export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8

echo "============================================================"
echo "  Build dataset: c256_$SIZE"
echo "  Clusters: $N_CLUSTERS,  bin-budget: $BIN_BUDGET,  workers: $WORKERS"
echo "  Output: $OUT_DIR"
echo "  Started: $(date -Iseconds)"
echo "============================================================"

step() { echo; echo "--- [$1] $(date -Iseconds) ---"; }

# 1. Histogram extraction (only for 56gb).
if [[ "$BUILD_HIST" == "1" ]]; then
    if [[ -f "$SRC_HIST" ]]; then
        echo "[1/5] $SRC_HIST already exists — skipping histogram extraction"
    else
        step "1/5 compute-histograms ($SRC_PQ → $SRC_HIST)"
        compute-histograms \
            -i "$SRC_PQ" \
            -o "$SRC_HIST" \
            --bin-range 10 20 \
            --seed "$SEED" \
            -w "$WORKERS" \
            --log-file "$LOG_DIR/compute_histograms.log"
    fi
else
    echo "[1/5] reusing existing $SRC_HIST"
fi

# 2. Cluster the histograms.
CLUSTERING="$OUT_DIR/clustering.zst"
if [[ -f "$CLUSTERING" ]]; then
    echo "[2/5] $CLUSTERING already exists — skipping clustering"
else
    step "2/5 cluster-histograms (k=$N_CLUSTERS, b=$BIN_BUDGET)"
    cluster-histograms \
        -i "$SRC_HIST" \
        -o "$CLUSTERING" \
        -a kmeans \
        -c "$N_CLUSTERS" "$N_CLUSTERS" \
        -b "$BIN_BUDGET" \
        -t quantile \
        --alpha 1 \
        --seed "$SEED" \
        -w "$WORKERS" \
        --log-level INFO \
        --log-file "$LOG_DIR/clustering.log"
fi

# 3. Build the rebinning percentile index (.zst pickle format).
ZST_INDEX="$OUT_DIR/indices/best_config_rebinning.zst"
if [[ -f "$ZST_INDEX" ]]; then
    echo "[3/5] $ZST_INDEX already exists — skipping create-index"
else
    step "3/5 create-index (rebinning, float32)"
    create-index \
        -i "$CLUSTERING" \
        -m rebinning \
        -p float32 \
        -o "$OUT_DIR/indices" \
        --index-file best_config_rebinning.zst \
        -w "$WORKERS" \
        --log-level INFO \
        --log-file "$LOG_DIR/create_index.log"
fi

# 4. Convert .zst → .fidx (flat binary, mmap-able).
FIDX_INDEX="$OUT_DIR/indices/best_config_rebinning.fidx"
if [[ -d "$FIDX_INDEX" ]]; then
    echo "[4/5] $FIDX_INDEX already exists — skipping fidx conversion"
else
    step "4/5 convert .zst → .fidx"
    python3 - <<PYEOF
import sys; sys.path.insert(0, '.')
from fainder.utils import load_input, save_flat_index
print('  loading $ZST_INDEX ...')
pctl, bins = load_input('$ZST_INDEX')
print(f'  loaded ({len(pctl)} clusters)')
print('  saving $FIDX_INDEX ...')
save_flat_index('$FIDX_INDEX', pctl, bins)
print('  done')
PYEOF
fi

# 5. Wire up queries (shared canonical query file across all 3 datasets).
QUERIES_DIR="$OUT_DIR/queries"
CANONICAL_QUERIES="$DATA_BASE/eval_medium/queries/all.zst"
if [[ -e "$QUERIES_DIR/all.zst" ]]; then
    echo "[5/5] queries already linked — skipping"
else
    step "5/5 wire queries (symlink → $CANONICAL_QUERIES)"
    mkdir -p "$QUERIES_DIR"
    ln -sf "$CANONICAL_QUERIES" "$QUERIES_DIR/all.zst"
fi

echo
echo "============================================================"
echo "  Build complete: c256_$SIZE — $(date -Iseconds)"
echo "  fidx:   $FIDX_INDEX"
echo "  queries: $QUERIES_DIR/all.zst"
echo "  Disk:"
du -sh "$OUT_DIR"
echo "============================================================"
