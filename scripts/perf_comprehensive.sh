#!/bin/bash
# Comprehensive perf-stat measurements on the current Rust engine.
#
# Uses perf --delay=40000 to skip ~35s of load+init+warmup so counters reflect
# the query phase only. Runs 5x full query set per thread-count.
#
# Three separate event groups to avoid heavy multiplexing:
#   Group A: CPU core (IPC, branches, branch-misses, stalled cycles)
#   Group B: Cache hierarchy (L1d, L3 references/misses)
#   Group C: LLC-specific (LLC-loads/misses) + memory events if available
#
# Usage:
#   bash scripts/perf_comprehensive.sh [eval_medium|eval_10gb|dev_small]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-eval_medium}"
case "$DATASET" in
  dev_small)   DATA_DIR="/home/abumukh-ldap/fainder-redone/data/dev_small"
               QDIR="/local-data/abumukh/data/gittables/dev_small"
               THREADS="1 16"  # small dataset; fewer thread counts
               DELAY_MS=3000
               export PERF_REPS=500 ;;  # 200 queries per run × 500 = 100k queries → ~20s at t=1
  eval_medium) DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"
               THREADS="1 16 64"
               DELAY_MS=40000 ;;
  eval_10gb)   DATA_DIR="/local-data/abumukh/data/gittables/eval_10gb"
               THREADS="1 16 64"
               DELAY_MS=25000 ;;
  *) echo "Unknown dataset: $DATASET"; exit 1 ;;
esac
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="${QDIR:-$DATA_DIR}/queries/all.zst"

LOGDIR="logs/perf"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)

cat > /tmp/perf_run.py <<'PYEOF'
import sys, os, time, numpy as np
from fainder.utils import load_input
from fainder.fainder_core import FainderIndex

idx_path = os.environ["PERF_INDEX"]
q_path = os.environ["PERF_QUERIES"]

pctl_index, bins = load_input(idx_path, name="index")
rust_input = [
    [(np.asarray(p, dtype=np.float32), np.asarray(i, dtype=np.uint32))
     for p, i in cluster]
    for cluster in pctl_index
]
fi = FainderIndex(rust_input, bins)

queries = load_input(q_path, name="queries")
qtuples = list(queries)

T = int(os.environ.get("PERF_THREADS", "1"))
# Warmup (Rayon pool + page-cache)
fi.run_queries(qtuples[:10], "precision", num_threads=T, suppress_results=True)

N_REPS = int(os.environ.get("PERF_REPS", "5"))
t0 = time.perf_counter()
for _ in range(N_REPS):
    fi.run_queries(qtuples, "precision", num_threads=T, suppress_results=True)
elapsed = time.perf_counter() - t0
sys.stderr.write(f"[py] run_queries x{N_REPS} (t={T}): {elapsed:.3f}s  (per run: {elapsed/N_REPS:.3f}s)\n")
PYEOF

run_perf() {
    local T="$1"; local EVENTS="$2"; local LABEL="$3"; local LOG="$4"
    echo "--- [$LABEL] t=$T ---" | tee -a "$LOG"
    PERF_INDEX="$INDEX" PERF_QUERIES="$QUERIES" PERF_THREADS="$T" \
        perf stat --delay="$DELAY_MS" -e "$EVENTS" \
        python /tmp/perf_run.py 2>&1 | tee -a "$LOG"
    echo "" | tee -a "$LOG"
}

EVENTS_CORE="instructions,cycles,branches,branch-misses,stalled-cycles-backend,stalled-cycles-frontend"
EVENTS_CACHE="L1-dcache-loads,L1-dcache-load-misses,cache-references,cache-misses"
EVENTS_LLC="LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses"

for T in $THREADS; do
    LOG="$LOGDIR/${DATASET}-t${T}-${TS}.log"
    echo "=== $DATASET t=$T ===" | tee "$LOG"
    run_perf "$T" "$EVENTS_CORE"  "CORE"  "$LOG"
    run_perf "$T" "$EVENTS_CACHE" "CACHE" "$LOG"
    run_perf "$T" "$EVENTS_LLC"   "LLC"   "$LOG"
done

echo ""
echo "Logs: $LOGDIR/"
