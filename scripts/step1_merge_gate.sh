#!/usr/bin/env bash
# Step (1) measurement gate for the Roaring decision.
#
# Runs three builds × two modes (with-results / suppress-results) × 5 repeats
# at t=16 against eval_medium. Writes rows to logs/bench.db tagged with
# label="step1_with_results" or "step1_supp_results" so the final SQL
# query can compute the merge-phase share per build.
#
# Builds compared:
#   default     : maturin develop --release   (no extra features)
#   bestofsuite : maturin develop --release --features "pooled f16 simd pin-cores cluster-prefetch mimalloc"
#   python      : Python baseline (no Rust path); uses FAINDER_NO_RUST=1
#
# Decision rule (post-run): if merge_share > 30% on any build → step (2) Roaring.
# If merge_share ≤ 15% across the board → footnote.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
INDEX="/local-data/abumukh/data/gittables/eval_medium/indices/best_config_rebinning.fidx"
QUERIES="/local-data/abumukh/data/gittables/eval_medium/queries/all.zst"
THREADS=16
# Median of 3 is sufficient for a gate decision; with-results runs on a
# GitTables-scale index can take 5–15 min each (Python boundary boxing
# dominates), so 3 repeats per (build × mode) keeps total under ~2 hours.
REPEATS=3

cd "$REPO"
source venv/bin/activate

echo "==============================================================="
echo " Step (1) merge-share measurement"
echo " Index:   $INDEX"
echo " Queries: $QUERIES"
echo " Threads: $THREADS,  Repeats: $REPEATS"
echo "==============================================================="

run_pair() {
    local label="$1"
    echo
    echo "--- Build: $label ---"

    echo "[$label] with-results (FAINDER_SUPPRESS_RESULTS=0)"
    FAINDER_SUPPRESS_RESULTS=0 scripts/bench.py \
        --build "$label" --threads "$THREADS" --repeats "$REPEATS" \
        --index "$INDEX" --queries "$QUERIES" \
        --label "step1_with_results"

    echo "[$label] suppress-results (FAINDER_SUPPRESS_RESULTS=1)"
    FAINDER_SUPPRESS_RESULTS=1 scripts/bench.py \
        --build "$label" --threads "$THREADS" --repeats "$REPEATS" \
        --index "$INDEX" --queries "$QUERIES" \
        --label "step1_supp_results"
}

# Build 1: default Rust ----------------------------------------------------
echo
echo "Building: default (no features)..."
maturin develop --release -q 2>&1 | tail -1
run_pair "default"

# Build 2: best-of-suite ---------------------------------------------------
echo
echo "Building: bestofsuite (pooled f16 simd pin-cores cluster-prefetch mimalloc)..."
maturin develop --release --features "pooled f16 simd pin-cores cluster-prefetch mimalloc" -q 2>&1 | tail -1
run_pair "bestofsuite"

# Python baseline intentionally omitted — the merge-share gate decision
# is a property of the Rust path (which is what we're going to ship).
# Comparing Python vs Rust under with-results is a separate, longer-running
# benchmark for the chapter narrative; not needed to decide whether
# Roaring is worth implementing.

echo
echo "==============================================================="
echo " All runs complete. Computing gate metric…"
echo "==============================================================="
python3 "$REPO/scripts/step1_report.py"
