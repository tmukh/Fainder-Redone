#!/bin/bash
# Full pipeline benchmark: every stage optimized.
#
# Measures four query-execution configurations at a thread sweep:
#   py      - Python searchsorted, .zst pickle load
#   f32     - Rust row-centric f32,  .fidx mmap
#   f16     - Rust row-centric f16,  .fidx mmap  (in-memory f16 conversion)
#   colf16  - Rust columnar + f16,   .fidx mmap  (NEW combination)
#
# Usage: bash scripts/benchmark_full_pipeline.sh [eval_medium|dev_small]

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
source venv/bin/activate

DATASET="${1:-eval_medium}"
DATA_BASE="/local-data/abumukh/data/gittables"
DATA_DIR="$DATA_BASE/$DATASET"
INDEX_ZST="$DATA_DIR/indices/best_config_rebinning.zst"
INDEX_FIDX="$DATA_DIR/indices/best_config_rebinning.fidx"
QUERIES="$DATA_DIR/queries/all.zst"

LOGDIR="logs/full_pipeline"
mkdir -p "$LOGDIR"
TS=$(date +%Y%m%d_%H%M%S)
SUMLOG="$LOGDIR/${DATASET}-summary-${TS}.log"

THREADS=(1 2 4 8 16 32 64)
TMPDIR_DATA=$(mktemp -d)
trap "rm -rf $TMPDIR_DATA" EXIT

echo "Full pipeline benchmark: $DATASET  ($(date))" | tee "$SUMLOG"
echo "" | tee -a "$SUMLOG"

# Extract query time from a run-queries log
extract_qt() {
    python3 -c "
import re, sys
txt = open(sys.argv[1]).read()
# Prefer precise engine-only timing over total (total includes FainderIndex init ~17s)
for pat in [r'Rust index-based query execution time: ([0-9.e+-]+)s',
            r'Raw index-based query execution time: ([0-9.e+-]+)s',
            r'Ran \d+ queries in ([0-9.e+-]+)s']:
    m = re.search(pat, txt)
    if m:
        print(m.group(1)); sys.exit()
print('ERR')
" "$1" 2>/dev/null
}

# Run one config; write qtimes to $TMPDIR_DATA/$label
run_config() {
    local label="$1" idx="$2" itype="$3"; shift 3
    # remaining args are env vars to prepend
    echo "--- $label ---" | tee -a "$SUMLOG"
    rm -f "$TMPDIR_DATA/$label"
    for t in "${THREADS[@]}"; do
        local lf="$LOGDIR/${DATASET}-${label}-t${t}.log"
        env "$@" FAINDER_NUM_THREADS=$t \
            run-queries -i "$idx" -t "$itype" -q "$QUERIES" \
            -m recall --suppress-results \
            --log-level DEBUG --log-file "$lf" 2>/dev/null
        local qt
        qt=$(extract_qt "$lf")
        echo "  t=$t  ${qt}s" | tee -a "$SUMLOG"
        echo "$qt" >> "$TMPDIR_DATA/$label"
    done
    echo "" | tee -a "$SUMLOG"
}

# ── 1. Python baseline (.zst, no Rust) ───────────────────────────────────────
run_config "py" "$INDEX_ZST" "index" "FAINDER_NO_RUST=1"

# ── 2. Rust f32 (.fidx mmap) ─────────────────────────────────────────────────
echo "Building Rust f32..." | tee -a "$SUMLOG"
maturin develop --release -q 2>&1 | tail -1 | tee -a "$SUMLOG"; echo "" | tee -a "$SUMLOG"
run_config "f32" "$INDEX_FIDX" "index"

# ── 3. Rust f16 (.fidx mmap, in-memory f16) ──────────────────────────────────
echo "Building Rust f16..." | tee -a "$SUMLOG"
maturin develop --release --features f16 -q 2>&1 | tail -1 | tee -a "$SUMLOG"; echo "" | tee -a "$SUMLOG"
run_config "f16" "$INDEX_FIDX" "index"

# ── 4. Rust columnar+f16 (.fidx mmap) ────────────────────────────────────────
run_config "colf16" "$INDEX_FIDX" "index" "FAINDER_COLUMNAR=1"

# Restore default build
echo "Restoring default build..." | tee -a "$SUMLOG"
maturin develop --release -q 2>&1 | tail -1 | tee -a "$SUMLOG"

# ── Summary ───────────────────────────────────────────────────────────────────
python3 - "$DATASET" "$TMPDIR_DATA" <<'PYEOF' 2>&1 | tee -a "$SUMLOG"
import sys, os
dataset = sys.argv[1]
td = sys.argv[2]
threads = [1, 2, 4, 8, 16, 32, 64]

def load(label):
    p = os.path.join(td, label)
    if not os.path.exists(p):
        return ['ERR']*7
    lines = open(p).read().strip().split('\n')
    return (lines + ['ERR']*7)[:7]

py     = load('py')
f32    = load('f32')
f16    = load('f16')
colf16 = load('colf16')

def fv(v):
    try: return float(v)
    except: return None
def fmt(v): return f"{fv(v):.3f}" if fv(v) else "  ERR"
def sp(b, v):
    bv, vv = fv(b), fv(v)
    return f"{bv/vv:.2f}×" if bv and vv else "  ---"
def best(lst):
    vals = [fv(x) for x in lst if fv(x)]
    return min(vals) if vals else None
def best_t(lst):
    vals = [(fv(x), threads[i]) for i, x in enumerate(lst) if fv(x)]
    return min(vals)[1] if vals else None

print()
print("=" * 74)
print(f" Query execution (suppress_results=True) — {dataset}")
print("=" * 74)
print(f"{'t':>4} | {'Python':>9} | {'Rust f32':>9} | {'Rust f16':>9} | {'Col+f16':>9} | {'f16/py':>8} | {'cf16/py':>8}")
print("-" * 74)
for i, t in enumerate(threads):
    print(f"{t:>4} | {fmt(py[i]):>9} | {fmt(f32[i]):>9} | {fmt(f16[i]):>9} | {fmt(colf16[i]):>9} | {sp(py[i],f16[i]):>8} | {sp(py[i],colf16[i]):>8}")

py_b = best(py); f32_b = best(f32); f16_b = best(f16); cf16_b = best(colf16)
print()
print(f"Best Python:     {py_b:.3f}s")
if f32_b:  print(f"Best Rust f32:   {f32_b:.3f}s  ({py_b/f32_b:.2f}× over Python)  at t={best_t(f32)}")
if f16_b:  print(f"Best Rust f16:   {f16_b:.3f}s  ({py_b/f16_b:.2f}× over Python)  at t={best_t(f16)}")
if cf16_b: print(f"Best col+f16:    {cf16_b:.3f}s  ({py_b/cf16_b:.2f}× over Python)  at t={best_t(colf16)}")

# Pick best Rust config
best_rs_b = min(x for x in [f16_b, cf16_b] if x)
best_rs_lbl = "col+f16" if cf16_b and cf16_b <= f16_b else "f16"

# Full pipeline timings (with load)
py_load = 15.2; mmap_load = 0.013
py_build = 492.87; rs_build = 129.79

print()
print("=" * 74)
print(" Load + query (per batch, pre-built index)")
print("=" * 74)
py_lq  = py_load + py_b
rs_lq  = mmap_load + best_rs_b
print(f"  Python (pickle {py_load}s + query {py_b:.3f}s):         {py_lq:.2f}s")
print(f"  Rust {best_rs_lbl} (mmap {mmap_load}s + query {best_rs_b:.3f}s):  {rs_lq:.3f}s")
print(f"  Speedup (load+query):  {py_lq/rs_lq:.2f}×")

print()
print("=" * 74)
print(" Full pipeline: build + load + query (one-shot)")
print("=" * 74)
py_e2e = py_build + py_load + py_b
rs_e2e = rs_build + mmap_load + best_rs_b
print(f"  Python:  build {py_build:.0f}s  + load {py_load:.1f}s  + query {py_b:.3f}s  = {py_e2e:.0f}s")
print(f"  Rust:    build {rs_build:.0f}s  + load {mmap_load}s  + query {best_rs_b:.3f}s  = {rs_e2e:.1f}s")
print(f"  Speedup (full e2e):    {py_e2e/rs_e2e:.2f}×")

print()
print("=" * 74)
print(" Repeated query batches (N=100, pre-built index)")
print("=" * 74)
print(f"  Python:  100 × ({py_load}s + {py_b:.3f}s) = {100*py_lq:.0f}s")
print(f"  Rust:    100 × ({mmap_load}s + {best_rs_b:.3f}s) = {100*rs_lq:.0f}s")
print(f"  Speedup: {100*py_lq / (100*rs_lq):.2f}×  [{py_lq:.2f}s → {rs_lq:.3f}s per batch]")
PYEOF

echo ""
echo "Full log: $SUMLOG"
