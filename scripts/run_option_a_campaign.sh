#!/bin/bash
# Option A campaign: re-measure the highest-impact ablations with min-of-3
# methodology on the post-cutover (target-cpu=native) binary.
#
# Builds (each compared against the others on identical thread sweep):
#   default              — baseline (no extra features)
#   pooled               — pre-allocated output buffer
#   pooled+f16           — + half-precision values
#   pooled+f16+pin       — + physical-core pinning
#   pooled+f16+pin+mim   — + mimalloc allocator (current headline)
#   columnar             — column-centric engine (single-thread regime winner)
#   eytzinger            — BFS layout (LLC-pressure regime)
#   kary                 — 4-way k-ary search
#
# Plus one Python baseline sweep at t=1 (the headline 18.27s denominator).
#
# Each (build, threads) pair runs 3 repeats. Min is reported.
# All runs go through scripts/bench.py:
#   - perf stat captures cycles/instructions/L1/LLC/branch counters
#   - rows are written to logs/bench.db
#   - metrics are pushed to Prometheus pushgateway for live Grafana visibility
#
# Total time estimate:
#   75 ablation runs × ~10s avg + 5 builds × ~60s build = ~20 minutes
#   Plus Python baseline sweep: 5 thread counts × 3 repeats × ~20s = ~5 min
#   Plus index loading (mmap, ~5s × ~100 = ~8 min worst case but page-cached)
#   ~30-40 minutes total.

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATA_DIR="/local-data/abumukh/data/gittables/eval_medium"
INDEX="$DATA_DIR/indices/best_config_rebinning.zst"
QUERIES="$DATA_DIR/queries/all.zst"

if [[ ! -f "$INDEX" ]] || [[ ! -f "$QUERIES" ]]; then
    echo "ERROR: missing index or queries:"
    echo "  $INDEX"
    echo "  $QUERIES"
    exit 1
fi

# Verify observability stack is up before starting
if ! curl -sf -o /dev/null http://localhost:9091/-/ready 2>&1; then
    echo "Pushgateway not responding on :9091 — start observability stack:"
    echo "  bash scripts/start_observability.sh start"
    exit 1
fi

THREADS_CSV="1,8,16,32,64"

# Builds to evaluate (build label, cargo features)
declare -a BUILD_FEATURES=(
    "default:"
    "pooled:pooled"
    "pooled-f16:pooled f16"
    "pooled-f16-pin:pooled f16 pin-cores"
    "pooled-f16-pin-mim:pooled f16 pin-cores mimalloc"
    "columnar:"            # default features; columnar engaged via FAINDER_COLUMNAR=1
    "eytzinger:eytzinger"
    "kary:kary"
)

run_build() {
    local label_features="$1"
    local label="${label_features%%:*}"
    local features="${label_features#*:}"

    echo ""
    echo "============================================================"
    echo "Build: $label  (features=\"$features\")"
    echo "============================================================"
    if [[ -z "$features" ]]; then
        maturin develop --release -q 2>&1 | tail -1
    else
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    fi

    # columnar build uses default code but FAINDER_COLUMNAR=1 env to engage column engine
    if [[ "$label" == "columnar" ]]; then
        FAINDER_COLUMNAR=1 python scripts/bench.py \
            --build "$label" --sweep "$THREADS_CSV" --repeats 3 \
            --index "$INDEX" --queries "$QUERIES" --label "native"
    else
        python scripts/bench.py \
            --build "$label" --sweep "$THREADS_CSV" --repeats 3 \
            --index "$INDEX" --queries "$QUERIES" --label "native"
    fi
}

run_python_baseline() {
    echo ""
    echo "============================================================"
    echo "Python baseline (FAINDER_NO_RUST=1) — t=1 only"
    echo "============================================================"
    # Python doesn't use Rayon; just run with t=1 several times for variance.
    FAINDER_NO_RUST=1 python scripts/bench.py \
        --build "python-baseline" --threads 1 --repeats 3 \
        --index "$INDEX" --queries "$QUERIES" --label "native" --no-perf || true
}

# Run them all
echo "Starting Option A campaign at $(date)"

run_python_baseline

for bf in "${BUILD_FEATURES[@]}"; do
    run_build "$bf"
done

# Restore default build
maturin develop --release -q 2>&1 | tail -1

echo ""
echo "============================================================"
echo "Campaign complete at $(date). Summary from logs/bench.db:"
echo "============================================================"
python -c "
import sqlite3
con = sqlite3.connect('logs/bench.db')
print(f'{'Build':<22} {'t=1':>9} {'t=8':>9} {'t=16':>9} {'t=32':>9} {'t=64':>9}')
print('-' * 70)
builds = [r[0] for r in con.execute('SELECT DISTINCT build FROM runs ORDER BY build').fetchall()]
for b in builds:
    row = [b]
    for t in (1, 8, 16, 32, 64):
        r = con.execute('SELECT MIN(wall_s) FROM runs WHERE build=? AND threads=?', (b, t)).fetchone()
        row.append(f'{r[0]:.3f}s' if r and r[0] is not None else '-')
    print(f'{row[0]:<22} {row[1]:>9} {row[2]:>9} {row[3]:>9} {row[4]:>9} {row[5]:>9}')
"
