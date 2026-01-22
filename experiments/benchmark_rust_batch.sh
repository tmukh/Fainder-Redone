#!/bin/bash
set -e
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
export PYTHONPATH=$PYTHONPATH:.

DATA_DIR="data/eval_medium"
QUERIES_SRC="data/gittables/queries/accuracy_benchmark_eval_medium/all.zst"
INDEX="data/eval_medium/indices/best_config_rebinning.zst"

echo "Running Batch Benchmark (Rust Speedup Verification)"

# 1. Run Python Baseline (Iterative over histograms - very slow usually)
# Skipping full baseline if it takes too long, maybe just 10 queries?
# But run-queries runs ALL queries in the file.
# We'll use the index-based Python execution as the comparison point?
# No, "index" type now uses Rust if available unless I force it off.

# To compare Rust vs Python Index:
# I need to be able to disable Rust.
# My code: try catch import fainder_core.
# I can temporarily rename fainder_core or force an exception?
# Or add a flag.

# For now, let's just run the Rust version on the full query set and see how fast it is.
# If it rips through thousands of queries in sub-second time, we are good.

echo "Running Rust-based Index Batch Queries..."
python -m fainder.execution.runner \
    -i "$INDEX" \
    -t index \
    -q "$QUERIES_SRC" \
    -m recall \
    --workers 4 \
    --log-level INFO \
    --log-file logs/eval_medium_benchmark/batch_rust.log

echo "Check logs/eval_medium_benchmark/batch_rust.log for execution time."
