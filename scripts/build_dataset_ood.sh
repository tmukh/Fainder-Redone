#!/usr/bin/env bash
# Out-of-distribution dataset build for Phase 2 dispatch-on-regime
# generalisation probe. Reuses the c256_56gb histograms file but re-clusters
# at a non-256 K, keeping bins-per-cluster roughly constant (~100) so the
# only varying methodology axis is the cluster-count regime.
#
# Usage:  scripts/build_dataset_ood.sh <K>
# Example: scripts/build_dataset_ood.sh 1024
#
# Pre-registered prediction (per cowork's framing):
#   - Confirmation: dispatch's prediction (build features × n_threads) at the
#     new K stays within 5% of the actually-best build → Claim 2
#     (dispatch-on-regime) becomes robust to cluster-count variation.
#   - Falsification: dispatch mispredicts at the new K → 4th regime cell
#     identified; document the new boundary and update dispatch.py.
# Either outcome strengthens the thesis (cowork's "smart hedge").

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <K>" >&2
    echo "  K = target number of clusters (e.g. 1024 for sparse-regime)" >&2
    exit 1
fi

K="$1"
REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SRC_HIST="$DATA_BASE/c256_56gb/histograms.zst"
OUT_DIR="$DATA_BASE/c${K}_56gb"

# Keep bins-per-cluster constant at 100 to match the existing methodology
# (c256_56gb: K=256, b=25600, 100 bins/cluster). Sparser cluster regime
# at the same per-cluster bin density isolates the K axis cleanly.
BIN_BUDGET=$(( K * 100 ))
SEED=42
WORKERS=96

LOG_DIR="$OUT_DIR/build_logs"
mkdir -p "$OUT_DIR/indices" "$LOG_DIR"

cd "$REPO"
source venv/bin/activate

export OPENBLAS_NUM_THREADS=8
export OMP_NUM_THREADS=8
export MKL_NUM_THREADS=8

echo "============================================================"
echo "  OOD build: c${K}_56gb"
echo "  K = $K (target),  bins-budget = $BIN_BUDGET (~100 per cluster)"
echo "  Reusing $SRC_HIST"
echo "  Output: $OUT_DIR"
echo "  Started: $(date -Iseconds)"
echo "============================================================"

step() { echo; echo "--- [$1] $(date -Iseconds) ---"; }

# 1. Histogram extraction — REUSE the c256_56gb file. No work.
echo "[1/5] reusing existing $SRC_HIST"

# 2. Cluster the histograms at the new K.
CLUSTERING="$OUT_DIR/clustering.zst"
if [[ -f "$CLUSTERING" ]]; then
    echo "[2/5] $CLUSTERING already exists — skipping clustering"
else
    step "2/5 cluster-histograms (k=$K, b=$BIN_BUDGET)"
    cluster-histograms \
        -i "$SRC_HIST" \
        -o "$CLUSTERING" \
        -a kmeans \
        -c "$K" "$K" \
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

# 5. Wire up queries (shared canonical query file).
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
echo "  OOD build complete: c${K}_56gb — $(date -Iseconds)"
echo "  fidx:   $FIDX_INDEX"
echo "  queries: $QUERIES_DIR/all.zst"
echo "  Disk:"
du -sh "$OUT_DIR"
echo "============================================================"
