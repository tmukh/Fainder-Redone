#!/bin/bash
# Benchmark Rust vs Python rebinning index construction.
#
# Usage:
#   bash scripts/benchmark_rebinning.sh [dataset]
#   dataset: dev_small (default) | eval_medium

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-dev_small}"
case "$DATASET" in
  dev_small)   DATA_DIR="/local-data/abumukh/data/gittables/dev_small" ;;
  eval_medium) DATA_DIR="/local-data/abumukh/data/gittables/eval_medium" ;;
  eval_10gb)   DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb" ;;
  *) echo "Unknown dataset: $DATASET"; exit 1 ;;
esac

LOGDIR="logs/rebinning"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)
LOG="$LOGDIR/${DATASET}-${TS}.log"

echo "=== Rebinning benchmark: $DATASET ===" | tee "$LOG"
echo "" | tee -a "$LOG"

python - <<PYEOF 2>&1 | tee -a "$LOG"
import sys, time, numpy as np, logging, os, glob
logging.basicConfig(level=logging.WARNING)
sys.path.insert(0, "$(pwd)")

CLUST_PATH = "$DATA_DIR/clustering.zst"
QUERY_DIR  = "$DATA_DIR/queries"
DATASET    = "$DATASET"
N_RUNS     = 3

from fainder.utils import load_input
from fainder.preprocessing.percentile_index import create_index
import fainder.preprocessing.percentile_index as pix
from fainder.execution.percentile_queries import query_index

clustered_hists, cluster_bins = load_input(CLUST_PATH, name="clustering")
n_hists = sum(len(c) for c in clustered_hists)
print(f"Dataset: {DATASET}  |  {n_hists:,} histograms  |  {len(clustered_hists)} clusters")
print()

# Python 1 worker
pix._RUST_REBINNING = False
times_py1 = []
for r in range(N_RUNS):
    t0 = time.perf_counter()
    create_index(clustered_hists, cluster_bins, "rebinning", "float32", "continuous_value", workers=1)
    times_py1.append(time.perf_counter() - t0)
py1 = sorted(times_py1)[N_RUNS//2]
print(f"Python (1 worker):   {py1:.2f}s  [runs: {', '.join(f'{t:.2f}s' for t in times_py1)}]")

# Rust (Rayon)
pix._RUST_REBINNING = True
times_rs = []
rs_index = None
for r in range(N_RUNS):
    t0 = time.perf_counter()
    rs_result = create_index(clustered_hists, cluster_bins, "rebinning", "float32", "continuous_value", workers=1)
    times_rs.append(time.perf_counter() - t0)
    rs_index = rs_result[0]
rs = sorted(times_rs)[N_RUNS//2]
print(f"Rust (Rayon):        {rs:.2f}s  [runs: {', '.join(f'{t:.2f}s' for t in times_rs)}]")
print()
print(f"Speedup (Rust vs Python 1w):  {py1/rs:.2f}x")
print()

# Correctness check
pix._RUST_REBINNING = False
py_index, _, _ = create_index(clustered_hists, cluster_bins, "rebinning", "float32", "continuous_value", workers=1)
query_files = sorted(glob.glob(f"{QUERY_DIR}/*.zst"))
if not query_files:
    print("No query files found — skipping correctness check")
else:
    # Use 'all.zst' if available (3-tuple queries); skip metrics files
    qfile = next((f for f in query_files if "all.zst" in f or "percentile" in f), query_files[0])
    queries = load_input(qfile, name="queries")[:20]
    py_res = query_index(py_index, cluster_bins, "precision", queries, n_workers=1)
    rs_res = query_index(rs_index, cluster_bins, "precision", queries, n_workers=1)
    n_diff = sum(1 for a, b in zip(py_res, rs_res) if a != b)
    status = "PASS" if n_diff == 0 else f"FAIL ({n_diff} mismatches)"
    print(f"Correctness: {status} — {len(queries)} queries compared")
PYEOF

echo "" | tee -a "$LOG"
echo "Log saved: $LOG"
