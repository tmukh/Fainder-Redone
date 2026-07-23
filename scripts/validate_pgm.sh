#!/usr/bin/env bash
# Correctness check: PGM-enabled build must produce byte-identical result sets
# to the default build on the same queries.
#
# 1. Build default → run queries with --output → save results
# 2. Build pgm → run queries with --output → save results
# 3. Diff the two pickle files (both are zstd-compressed pickle of (queries, results))

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="${1:-10gb}"  # default: smallest dataset for fast iteration
INDEX="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/c256_$SIZE/queries/all.zst"
OUT_DEFAULT="/tmp/pgm_validate_default_$SIZE.zst"
OUT_PGM="/tmp/pgm_validate_pgm_$SIZE.zst"

cd "$REPO"
source venv/bin/activate

echo "============================================================"
echo " PGM correctness validation on c256_$SIZE"
echo " Index:   $INDEX"
echo " Queries: $QUERIES"
echo "============================================================"

echo
echo "[1/3] Building default (no features)..."
maturin develop --release -q 2>&1 | tail -1

echo "[1/3] Running queries on default build..."
FAINDER_NUM_THREADS=16 run-queries \
    -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_DEFAULT" \
    --log-level INFO --log-file /tmp/pgm_validate_default.log 2>&1 | tail -5

echo
echo "[2/3] Building --features pgm..."
maturin develop --release --features pgm -q 2>&1 | tail -1

echo "[2/3] Running queries on pgm build..."
FAINDER_NUM_THREADS=16 run-queries \
    -i "$INDEX" -t index -q "$QUERIES" -m recall \
    --output "$OUT_PGM" \
    --log-level INFO --log-file /tmp/pgm_validate_pgm.log 2>&1 | tail -5

echo
echo "[3/3] Diffing result sets..."
python3 <<EOF
import zstandard as zstd
import pickle

def load(path):
    with open(path, 'rb') as f:
        return pickle.load(zstd.ZstdDecompressor().stream_reader(f))

q_d, r_d = load("$OUT_DEFAULT")
q_p, r_p = load("$OUT_PGM")

assert q_d == q_p, "queries differ between runs"
n = len(r_d)
mismatches = []
total_d_size = 0
total_p_size = 0
for i, (rd, rp) in enumerate(zip(r_d, r_p)):
    total_d_size += len(rd)
    total_p_size += len(rp)
    if rd != rp:
        # Find which IDs differ
        only_d = rd - rp
        only_p = rp - rd
        mismatches.append((i, len(only_d), len(only_p)))

print(f"  total queries:           {n}")
print(f"  total result-set size:   default={total_d_size}, pgm={total_p_size}")
if mismatches:
    print(f"  ❌ MISMATCHES:           {len(mismatches)}/{n} queries differ")
    print(f"  first 5 mismatches:")
    for q_idx, n_d_only, n_p_only in mismatches[:5]:
        print(f"    query {q_idx}: default-only={n_d_only}, pgm-only={n_p_only}")
    raise SystemExit(1)
else:
    print(f"  ✅ ALL {n} RESULT SETS BYTE-IDENTICAL — PGM CORRECTNESS VALIDATED")
EOF
