#!/bin/bash
# Per-source-line cache-miss attribution via perf record + perf annotate.
#
# Builds the Rust extension with line-level debug info, runs the query phase
# under perf record sampling LLC-load-misses and L1-dcache-load-misses, then
# emits a per-symbol breakdown and (optionally) per-line annotation.
#
# Usage:
#   bash scripts/perf_per_line.sh [eval_medium|dev_small]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-eval_medium}"
case "$DATASET" in
  dev_small)
    DATA_DIR="/home/abumukh-ldap/fainder-redone/data/dev_small"
    QDIR="/local-data/abumukh/data/gittables/dev_small"
    REPS=500    # need 500x to get >5s of measured runtime
    THREADS=1 ;;
  eval_medium)
    DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"
    QDIR="$DATA_DIR"
    REPS=5
    THREADS=1 ;;
  *) echo "Unknown dataset: $DATASET"; exit 1 ;;
esac
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="$QDIR/queries/all.zst"

LOGDIR="logs/perf_line"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)

# 1. Rebuild with line-level debug info
echo "=== Building Rust with profiling profile (debug=line-tables-only) ==="
maturin develop --profile profiling 2>&1 | tail -2

# 2. Generate the Python script that runs the measured query
cat > /tmp/perf_line_run.py <<PYEOF
import sys, os, time, numpy as np
from fainder.utils import load_input
from fainder.fainder_core import FainderIndex

idx_path = "$INDEX"
q_path   = "$QUERIES"
N_REPS   = $REPS
T        = $THREADS

pctl_index, bins = load_input(idx_path, name="index")
rust_input = [
    [(np.asarray(p, dtype=np.float32), np.asarray(i, dtype=np.uint32))
     for p, i in cluster]
    for cluster in pctl_index
]
fi = FainderIndex(rust_input, bins)
queries = list(load_input(q_path, name="queries"))

# Warm up
fi.run_queries(queries[:10], "precision", num_threads=T, suppress_results=True)

t0 = time.perf_counter()
for _ in range(N_REPS):
    fi.run_queries(queries, "precision", num_threads=T, suppress_results=True)
elapsed = time.perf_counter() - t0
sys.stderr.write(f"[py] {N_REPS}x query (t={T}): {elapsed:.2f}s ({elapsed/N_REPS:.3f}s/run)\n")
PYEOF

# 3. Run perf record on it
PERF_DATA="$LOGDIR/perf-${DATASET}-t${THREADS}-${TS}.data"
echo ""
echo "=== perf record (LLC + L1 misses, call-graph) ==="
echo "Output: $PERF_DATA"

# Sample LLC-load-misses heavily; also sample L1-dcache-load-misses.
# --call-graph dwarf uses dwarf unwinding (needs the debug info we built in).
# -F 999 = 999 Hz sampling rate (one sample every ~1ms per CPU).
perf record -F 999 \
    -e LLC-load-misses,L1-dcache-load-misses,cycles \
    --call-graph dwarf \
    -o "$PERF_DATA" \
    -- python /tmp/perf_line_run.py 2>&1 | tail -5

# 4. Per-symbol breakdown for each event
echo ""
echo "=== Per-symbol breakdown: LLC-load-misses ==="
perf report -i "$PERF_DATA" --stdio --no-children \
    --sort=overhead,symbol \
    --event=LLC-load-misses 2>/dev/null | head -40 \
    | tee "$LOGDIR/symbols-LLC-${DATASET}-t${THREADS}-${TS}.txt"

echo ""
echo "=== Per-symbol breakdown: L1-dcache-load-misses ==="
perf report -i "$PERF_DATA" --stdio --no-children \
    --sort=overhead,symbol \
    --event=L1-dcache-load-misses 2>/dev/null | head -40 \
    | tee "$LOGDIR/symbols-L1-${DATASET}-t${THREADS}-${TS}.txt"

echo ""
echo "=== Per-line annotation of top symbol (LLC) ==="
TOP_SYM=$(perf report -i "$PERF_DATA" --stdio --no-children \
    --sort=overhead,symbol --event=LLC-load-misses 2>/dev/null \
    | grep -E '^\s*[0-9]+\.[0-9]+%' | head -1 | awk '{print $NF}')
echo "Top LLC-miss symbol: $TOP_SYM"
if [[ -n "$TOP_SYM" ]]; then
    perf annotate -i "$PERF_DATA" --stdio --no-source-code-line=false \
        --event=LLC-load-misses --symbol="$TOP_SYM" 2>/dev/null \
        | head -120 \
        | tee "$LOGDIR/annotate-LLC-${DATASET}-t${THREADS}-${TS}.txt"
fi

echo ""
echo "Logs in: $LOGDIR/"
echo "To re-explore interactively:  perf report -i $PERF_DATA"
