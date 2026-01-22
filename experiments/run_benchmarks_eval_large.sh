#!/bin/bash
set -e
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
source .venv/bin/activate
export PYTHONPATH=$PYTHONPATH:.

DATA_DIR="data/eval_large"
QUERIES_SRC="data/gittables/queries/accuracy_benchmark_eval_large/all.zst"
INDEX="data/eval_large/indices/best_config_rebinning.zst"
HISTOGRAMS="data/eval_large/histograms.zst"
LOG_DIR="logs/eval_large_benchmark"

mkdir -p "$LOG_DIR"

echo "========================================================"
echo "Starting Large Scale Benchmark (1GB Dataset / 25k Files)"
echo "========================================================"

# 1. BATCH THROUGHPUT BENCHMARK (The real test)
# Compares Python Iterative (skip if too slow? maybe run subset?) vs Rust Index
# Actually, iterating 25k histograms per query for 90 queries = 2.25M checks.
# Python might take a while but it's the baseline.

echo "[1/3] Running Rust-based Index Batch Queries (Throughput)..."
start_rust=$(date +%s.%N)
python -m fainder.execution.runner \
    -i "$INDEX" \
    -t index \
    -q "$QUERIES_SRC" \
    -m recall \
    --workers 4 \
    --log-level INFO \
    --log-file "$LOG_DIR/batch_rust.log"
end_rust=$(date +%s.%N)
echo "Rust Batch Done. Log: $LOG_DIR/batch_rust.log"

echo "[2/3] Running Python Index Batch Queries (Throughput Baseline)..."
# We force Python backend using FAINDER_NO_RUST=1
start_py=$(date +%s.%N)
FAINDER_NO_RUST=1 python -m fainder.execution.runner \
    -i "$INDEX" \
    -t index \
    -q "$QUERIES_SRC" \
    -m recall \
    --workers 4 \
    --log-level INFO \
    --log-file "$LOG_DIR/batch_python.log"
end_py=$(date +%s.%N)
echo "Python Batch Done. Log: $LOG_DIR/batch_python.log"


# 2. SINGLE QUERY PROFILING (Optional, for deep dive)
QUERY_ARGS=("0.1" "lt" "50")
echo "[3/3] Profiling Single Query (Optional)..."
python -m fainder.execution.runner_single \
    -i "$INDEX" \
    -t index \
    -q "${QUERY_ARGS[@]}" \
    -m recall \
    --log-file "$LOG_DIR/single_query_rust.log"

# Calculate Speedup
dur_rust=$(echo "$end_rust - $start_rust" | bc)
dur_py=$(echo "$end_py - $start_py" | bc)

echo "========================================================"
echo "BENCHMARK RESULTS (Approx Wall Time)"
echo "Rust Duration:   $dur_rust seconds"
echo "Python Duration: $dur_py seconds"
echo "========================================================"
