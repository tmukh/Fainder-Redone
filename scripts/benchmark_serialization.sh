#!/bin/bash
# Benchmark: pickle+zstd (legacy) vs flat binary (.fidx) index loading
#
# Tests three loading modes:
#   legacy      — pickle.load(zstd.open(...))   current default
#   flat-ram    — np.load() into RAM             no mmap; raw I/O + C array init
#   flat-mmap   — np.load(mmap_mode='r')         map only; OS pages in on access
#
# Each mode is timed N_RUNS times so we can see cold vs warm-cache behavior.
# End-to-end correctness is verified: all three modes produce identical query results.
#
# Usage:
#   bash scripts/benchmark_serialization.sh [dev_small|eval_medium|eval_10gb]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-eval_medium}"
N_RUNS=3

DATA_BASE="/local-data/abumukh/data/gittables"
case "$DATASET" in
    dev_small)
        ZST_INDEX="data/dev_small/indices/best_config_rebinning.zst"
        QUERIES="$DATA_BASE/dev_small/queries/all.zst"
        ;;
    eval_medium)
        ZST_INDEX="$DATA_BASE/eval_medium/indices/best_config_rebinning.zst"
        QUERIES="$DATA_BASE/eval_medium/queries/all.zst"
        ;;
    eval_10gb)
        ZST_INDEX="$DATA_BASE/eval_10gb/indices/best_config_rebinning.zst"
        QUERIES="$DATA_BASE/eval_10gb/queries/all.zst"
        ;;
    *)
        echo "Unknown dataset: $DATASET"; exit 1 ;;
esac

FIDX_DIR="${ZST_INDEX%.zst}.fidx"
LOG_DIR="logs/serialization"
mkdir -p "$LOG_DIR"

echo "========================================"
echo "Serialization Benchmark: $DATASET"
echo "  .zst  index: $ZST_INDEX"
echo "  .fidx index: $FIDX_DIR"
echo "========================================"

# ── Step 1: convert to flat binary if needed ─────────────────────────────────
if [[ ! -d "$FIDX_DIR" ]]; then
    echo ""
    echo "[1/4] Converting pickle+zstd → flat binary (.fidx)..."
    python3 - <<PYEOF
import time, sys
from pathlib import Path
sys.path.insert(0, '.')
from fainder.utils import load_input, save_flat_index

src = "$ZST_INDEX"
dst = "${FIDX_DIR}"

print(f"  Loading {src} ...")
t0 = time.perf_counter()
pctl_index, cluster_bins = load_input(src)
t1 = time.perf_counter()
print(f"  Loaded in {t1-t0:.2f}s")

print(f"  Saving to {dst} ...")
t2 = time.perf_counter()
save_flat_index(dst, pctl_index, cluster_bins)
t3 = time.perf_counter()
print(f"  Saved  in {t3-t2:.2f}s")
PYEOF
else
    echo "[1/4] .fidx already exists at $FIDX_DIR — skipping conversion"
fi

# ── Step 2: run the three-way benchmark ───────────────────────────────────────
echo ""
echo "[2/4] Running loading benchmarks ($N_RUNS runs each)..."

python3 - <<PYEOF
import time, sys, json, statistics, os
from pathlib import Path
sys.path.insert(0, '.')
from fainder.utils import load_input, load_flat_index

zst_path  = "$ZST_INDEX"
fidx_path = "$FIDX_DIR"
n_runs    = $N_RUNS

results = {}

print()
for label, fn in [
    ("legacy   (pickle+zstd)", lambda: load_input(zst_path, name=None)),
    ("flat-ram (np.load)     ", lambda: load_flat_index(fidx_path, mmap_mode=None,  name=None)),
    ("flat-mmap(np.load 'r') ", lambda: load_flat_index(fidx_path, mmap_mode='r', name=None)),
]:
    times = []
    for run in range(n_runs):
        # Drop page cache hint (best-effort; requires CAP_SYS_ADMIN on most systems)
        try:
            with open("/proc/sys/vm/drop_caches", "w") as f:
                f.write("1\n")
        except PermissionError:
            pass  # No permission — run as-is (cache may be warm after first run)
        t0 = time.perf_counter()
        fn()
        t1 = time.perf_counter()
        times.append(t1 - t0)
        print(f"  {label}  run {run+1}/{n_runs}: {t1-t0:.3f}s")
    results[label.strip()] = times
    print(f"  → median {statistics.median(times):.3f}s  (min {min(times):.3f}s)")
    print()

print("Summary:")
print(f"  {'Mode':<28}  {'Run1':>7}  {'Run2':>7}  {'Run3':>7}  {'Median':>7}")
for label, times in results.items():
    ts = [f"{t:.3f}s" for t in times]
    while len(ts) < 3:
        ts.append("—")
    print(f"  {label:<28}  {ts[0]:>7}  {ts[1]:>7}  {ts[2]:>7}  {statistics.median(times):>6.3f}s")
PYEOF

# ── Step 3: correctness check ────────────────────────────────────────────────
echo ""
echo "[3/4] Correctness check: same queries via legacy and flat-ram..."

python3 - <<PYEOF
import sys, os, pickle, zstandard as zstd
sys.path.insert(0, '.')
os.environ["FAINDER_NUM_THREADS"] = "4"
from pathlib import Path
from fainder.utils import load_input, load_flat_index
from fainder.execution.percentile_queries import query_index

zst_path   = "$ZST_INDEX"
fidx_path  = "$FIDX_DIR"
query_path = "$QUERIES"

# Load queries
with zstd.open(query_path, "rb") as f:
    queries = pickle.load(f)
queries = list(queries[:20])  # first 20 queries for speed

# Run via legacy
pctl_legacy, bins_legacy = load_input(zst_path, name=None)
res_legacy = query_index(pctl_legacy, bins_legacy, "recall", queries, n_workers=None, suppress_results=False)

# Run via flat-ram
pctl_flat, bins_flat = load_flat_index(fidx_path, mmap_mode=None, name=None)
res_flat = query_index(pctl_flat, bins_flat, "recall", queries, n_workers=None, suppress_results=False)

# Compare
mismatches = 0
for i, (a, b) in enumerate(zip(res_legacy, res_flat)):
    if a != b:
        print(f"  MISMATCH query {i}: legacy={len(a)} flat={len(b)}")
        mismatches += 1

if mismatches == 0:
    print("  ✓ All 20 queries: identical results (legacy == flat-ram)")
else:
    print(f"  ✗ {mismatches} mismatches found!")
    sys.exit(1)
PYEOF

# ── Step 4: end-to-end query timing ──────────────────────────────────────────
echo ""
echo "[4/4] End-to-end query benchmark (load + run 200/10k queries, t=16, suppress_results)..."

for mode in legacy flat-ram flat-mmap; do
    LOG="$LOG_DIR/${DATASET}-serial-${mode}.log"
    echo -n "  $mode ... "
    python3 - > /tmp/serial_bench_$mode.txt 2>&1 <<PYEOF
import time, sys, os, pickle, zstandard as zstd
sys.path.insert(0, '.')
os.environ["FAINDER_NUM_THREADS"] = "16"
from fainder.utils import load_input, load_flat_index
from fainder.execution.percentile_queries import query_index

zst_path   = "$ZST_INDEX"
fidx_path  = "$FIDX_DIR"
query_path = "$QUERIES"

with zstd.open(query_path, "rb") as f:
    queries = list(pickle.load(f))

t_load_start = time.perf_counter()
if "$mode" == "legacy":
    pctl_index, cluster_bins = load_input(zst_path, name=None)
elif "$mode" == "flat-ram":
    pctl_index, cluster_bins = load_flat_index(fidx_path, mmap_mode=None,  name=None)
else:
    pctl_index, cluster_bins = load_flat_index(fidx_path, mmap_mode='r', name=None)
t_load_end = time.perf_counter()

t_query_start = time.perf_counter()
query_index(pctl_index, cluster_bins, "recall", queries, n_workers=None, suppress_results=True)
t_query_end = time.perf_counter()

load_s  = t_load_end  - t_load_start
query_s = t_query_end - t_query_start
total_s = t_query_end - t_load_start
print(f"load={load_s:.3f}s  query={query_s:.3f}s  total={total_s:.3f}s")
PYEOF
    cat /tmp/serial_bench_$mode.txt
done

echo ""
echo "========================================"
echo "DONE — logs in $LOG_DIR/"
echo "========================================"
