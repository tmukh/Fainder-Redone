#!/usr/bin/env bash
# Correctness check: morsel-scheduler build must produce byte-identical
# result sets to the default build on the same queries.
#
# Pattern follows scripts/validate_pgm.sh:
#   1. Build default → run queries with --output → save results
#   2. Build morsel → run queries with --output → save results
#   3. Diff the two zstd-compressed pickles of (queries, results).

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="${1:-10gb}"
INDEX="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/c256_$SIZE/queries/all.zst"
OUT_DEFAULT="/tmp/morsel_validate_default_$SIZE.zst"
OUT_MORSEL="/tmp/morsel_validate_morsel_$SIZE.zst"

cd "$REPO"
source venv/bin/activate

echo "============================================================"
echo " Morsel correctness validation on c256_$SIZE"
echo " Index:   $INDEX"
echo " Queries: $QUERIES"
echo "============================================================"

echo
echo "[1/3] Building default (no features)..."
maturin develop --release -q 2>&1 | tail -1

echo "[1/3] Running queries on default build (t=16)..."
FAINDER_NUM_THREADS=16 run-queries \
    -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_DEFAULT" \
    --log-level INFO --log-file /tmp/morsel_validate_default.log 2>&1 | tail -5

echo
echo "[2/3] Building --features morsel..."
maturin develop --release --features morsel -q 2>&1 | tail -1

echo "[2/3] Running queries on morsel build (t=16)..."
FAINDER_NUM_THREADS=16 run-queries \
    -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_MORSEL" \
    --log-level INFO --log-file /tmp/morsel_validate_morsel.log 2>&1 | tail -5

echo
echo "[3/3] Diffing result sets..."
python3 <<EOF
import zstandard as zstd
import pickle

def load(path):
    with open(path, 'rb') as f:
        return pickle.load(zstd.ZstdDecompressor().stream_reader(f))

q_d, r_d = load("$OUT_DEFAULT")
q_m, r_m = load("$OUT_MORSEL")

assert q_d == q_m, "queries differ between runs"
n = len(r_d)
mismatches = []
total_d_size = 0
total_m_size = 0
for i, (rd, rm) in enumerate(zip(r_d, r_m)):
    total_d_size += len(rd)
    total_m_size += len(rm)
    if rd != rm:
        only_d = rd - rm
        only_m = rm - rd
        mismatches.append((i, len(only_d), len(only_m)))

print(f"  total queries:           {n}")
print(f"  total result-set size:   default={total_d_size}, morsel={total_m_size}")
if mismatches:
    print(f"  ❌ MISMATCHES:           {len(mismatches)}/{n} queries differ")
    print(f"  first 5 mismatches:")
    for q_idx, n_d_only, n_m_only in mismatches[:5]:
        print(f"    query {q_idx}: default-only={n_d_only}, morsel-only={n_m_only}")
    raise SystemExit(1)
else:
    print(f"  ✅ ALL {n} RESULT SETS BYTE-IDENTICAL — MORSEL CORRECTNESS VALIDATED")
EOF
