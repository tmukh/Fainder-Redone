#!/usr/bin/env bash
# Correctness check for per-cluster reindexing (§3.11):
#   - --features local-ids must produce byte-identical results to default
#     (lookup → global ids, semantics unchanged from the consumer's POV).
#   - --features local-ids-bench must DIVERGE from default in with-results
#     mode (it emits local ids; sets will differ from global). This is the
#     suppress-mode-only diagnostic build.
#
# Pattern follows scripts/validate_morsel.sh.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="${1:-10gb}"
INDEX="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/c256_$SIZE/queries/all.zst"
OUT_DEFAULT="/tmp/local_ids_default_$SIZE.zst"
OUT_LOCAL="/tmp/local_ids_local_$SIZE.zst"
OUT_BENCH="/tmp/local_ids_bench_$SIZE.zst"

cd "$REPO"
source venv/bin/activate

echo "============================================================"
echo " local-ids correctness validation on c256_$SIZE"
echo "============================================================"

echo
echo "[1/4] Building default..."
maturin develop --release -q 2>&1 | tail -1
echo "[1/4] Running default (t=16)..."
FAINDER_NUM_THREADS=16 run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_DEFAULT" --log-level INFO --log-file /tmp/local_ids_default.log 2>&1 | tail -3

echo
echo "[2/4] Building --features local-ids..."
maturin develop --release --features local-ids -q 2>&1 | tail -1
echo "[2/4] Running local-ids (t=16)..."
FAINDER_NUM_THREADS=16 run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_LOCAL" --log-level INFO --log-file /tmp/local_ids_local.log 2>&1 | tail -3

echo
echo "[3/4] Building --features local-ids-bench..."
maturin develop --release --features local-ids-bench -q 2>&1 | tail -1
echo "[3/4] Running local-ids-bench (t=16)..."
FAINDER_NUM_THREADS=16 run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_BENCH" --log-level INFO --log-file /tmp/local_ids_bench.log 2>&1 | tail -3

echo
echo "[4/4] Diffing..."
python3 <<EOF
import zstandard as zstd
import pickle

def load(path):
    with open(path, 'rb') as f:
        return pickle.load(zstd.ZstdDecompressor().stream_reader(f))

q_d, r_d = load("$OUT_DEFAULT")
q_l, r_l = load("$OUT_LOCAL")
q_b, r_b = load("$OUT_BENCH")

assert q_d == q_l == q_b, "queries differ between runs"
n = len(r_d)

# local-ids should be byte-identical to default
mismatches_l = sum(1 for rd, rl in zip(r_d, r_l) if rd != rl)
total_d = sum(len(s) for s in r_d)
total_l = sum(len(s) for s in r_l)
print(f"  default vs local-ids:")
print(f"    total set sizes: default={total_d}, local-ids={total_l}")
if mismatches_l == 0:
    print(f"    ✅ ALL {n} RESULT SETS BYTE-IDENTICAL — option 1 (lookup) CORRECT")
else:
    print(f"    ❌ {mismatches_l}/{n} queries differ — option 1 is BROKEN, debug required")
    raise SystemExit(1)

# local-ids-bench should DIVERGE in with-results mode (emits local ids)
mismatches_b = sum(1 for rd, rb in zip(r_d, r_b) if rd != rb)
total_b = sum(len(s) for s in r_b)
print(f"  default vs local-ids-bench:")
print(f"    total set sizes: default={total_d}, local-ids-bench={total_b}")
if mismatches_b > 0:
    print(f"    ✅ {mismatches_b}/{n} queries differ as expected — option 4 emits LOCAL ids (suppress-mode only)")
else:
    print(f"    ⚠️  local-ids-bench MATCHES default — that means lookup is happening somewhere it shouldn't, or the test workload happens to have local==global. Inspect mechanism.")
EOF
