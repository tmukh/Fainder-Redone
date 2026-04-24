#!/bin/bash
# Measure branch misprediction, IPC, and cache miss rates on the Rust engine.
#
# Uses perf --delay=40000 (ms) to skip the ~35s of load+init+warmup overhead,
# so counters reflect the query-phase only (5 repeats of run_queries).
#
# Usage:
#   bash scripts/perf_branch_misses.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="eval_medium"
DATA_DIR="/local-data/abumukh/data/gittables/$DATASET"
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="$DATA_DIR/queries/all.zst"

LOGDIR="logs/perf_branch"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)

EVENTS="instructions,cycles,branches,branch-misses,cache-references,cache-misses,LLC-loads,LLC-load-misses"
# After process start, wait 40s before enabling counters. Load+init+warmup is ~35s.
DELAY_MS=40000

cat > /tmp/perf_run.py <<'PYEOF'
import sys, os, time, numpy as np
from fainder.utils import load_input
from fainder.fainder_core import FainderIndex

idx_path = os.environ["PERF_INDEX"]
q_path = os.environ["PERF_QUERIES"]

t0 = time.perf_counter()
pctl_index, bins = load_input(idx_path, name="index")
print(f"[py] load: {time.perf_counter()-t0:.3f}s", file=sys.stderr)

t0 = time.perf_counter()
rust_input = [
    [(np.asarray(p, dtype=np.float32), np.asarray(i, dtype=np.uint32))
     for p, i in cluster]
    for cluster in pctl_index
]
fi = FainderIndex(rust_input, bins)
print(f"[py] FainderIndex init: {time.perf_counter()-t0:.3f}s", file=sys.stderr)

queries = load_input(q_path, name="queries")
qtuples = list(queries)
print(f"[py] {len(qtuples)} queries loaded", file=sys.stderr)

T = int(os.environ.get("PERF_THREADS", "1"))

# Warm up: run query once so Rayon pool is allocated and pages are touched.
fi.run_queries(qtuples[:10], "precision", num_threads=T, suppress_results=True)

# After ~40s, perf starts measuring here. Keep the total setup <40s.
print(f"[py] setup complete at t={time.perf_counter():.1f} (wall)", file=sys.stderr)

# Measured: 5x full query set. perf --delay=40000 kicks in here.
N_REPS = int(os.environ.get("PERF_REPS", "5"))
t0 = time.perf_counter()
for _ in range(N_REPS):
    fi.run_queries(qtuples, "precision", num_threads=T, suppress_results=True)
elapsed = time.perf_counter() - t0
print(f"[py] run_queries x{N_REPS} (t={T}): {elapsed:.3f}s  (per run: {elapsed/N_REPS:.3f}s)", file=sys.stderr)
PYEOF

for T in 1 16; do
    LOG="$LOGDIR/t${T}-${TS}.log"
    echo "=== perf stat at t=$T (delay=${DELAY_MS}ms, 5x query) ===" | tee "$LOG"
    PERF_INDEX="$INDEX" PERF_QUERIES="$QUERIES" PERF_THREADS="$T" \
        perf stat --delay="$DELAY_MS" -e "$EVENTS" \
        python /tmp/perf_run.py 2>&1 | tee -a "$LOG"
    echo "" | tee -a "$LOG"
done

echo ""
echo "Logs: $LOGDIR/"
