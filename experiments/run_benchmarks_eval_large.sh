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


echo "[1/3] Running Iterative Baseline (scan histograms)..."
echo "Note: This can take ~10 minutes for 400 queries on eval_large."
start_base=$(date +%s.%N)
python -m fainder.execution.runner \
    -i "$HISTOGRAMS" \
    -t histograms \
    -q "$QUERIES_SRC" \
    -m recall \
    -e over \
    --workers 4 \
    --log-level INFO \
    --log-file "$LOG_DIR/batch_baseline.log"
end_base=$(date +%s.%N)
echo "Baseline Done. Log: $LOG_DIR/batch_baseline.log"

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
echo "Python Index Done. Log: $LOG_DIR/batch_python.log"

echo "[3/3] Running Rust-based Index Batch Queries (Throughput)..."
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
echo "Rust Index Done. Log: $LOG_DIR/batch_rust.log"

# Calculate durations using python to avoid 'bc' dependency
dur_base=$(python -c "print(f'{float($end_base) - float($start_base):.4f}')")
dur_py=$(python -c "print(f'{float($end_py) - float($start_py):.4f}')")
dur_rust=$(python -c "print(f'{float($end_rust) - float($start_rust):.4f}')")

echo "========================================================"
echo "BENCHMARK RESULTS (Approx Wall Time - 400 queries)"
echo "Baseline (Iterative): $dur_base seconds"
echo "Python Index:         $dur_py seconds"
echo "Rust Index:           $dur_rust seconds"
echo "========================================================"
echo "Speedup (Rust vs Baseline): $(python -c "print(f'{float($dur_base)/float($dur_rust):.2f}')")x"
echo "Speedup (Rust vs Python):   $(python -c "print(f'{float($dur_py)/float($dur_rust):.2f}')")x"
