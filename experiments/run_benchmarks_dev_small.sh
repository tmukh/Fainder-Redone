#!/bin/bash

echo "Executing runtime benchmark for dev_small"

set -euxo pipefail
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
start_time=$(date +%s)

# Define paths
DATA_DIR="data/dev_small"
# Original source of queries
QUERIES_SRC="data/gittables/queries/accuracy_benchmark_dev_small/all.zst"
# Indices created in setup (I created best_config_rebinning.zst)
INDEX="data/dev_small/indices/best_config_rebinning.zst"
HISTOGRAMS="data/dev_small/histograms.zst"

# Create log directory
mkdir -p logs/dev_small_benchmark

# 1. Run Query Collection
echo "Running query collection benchmark..."
run-queries \
    -i "$HISTOGRAMS" \
    -t histograms \
    -q "$QUERIES_SRC" \
    -e over \
    --log-file logs/dev_small_benchmark/collection-iterative.log

run-queries \
    -i "$INDEX" \
    -t index \
    -q "$QUERIES_SRC" \
    -m recall \
    --log-file logs/dev_small_benchmark/collection-rebinning.log

# 2. Single Query Benchmark
echo "Running single query benchmark..."
query=("0.1" "lt" "50")
run-query \
    -i "$HISTOGRAMS" \
    -t histograms \
    -q "${query[@]}" \
    -e over \
    --log-file logs/dev_small_benchmark/query-iterative.log

run-query \
    -i "$INDEX" \
    -t index \
    -q "${query[@]}" \
    -m recall \
    --log-file logs/dev_small_benchmark/query-rebinning.log

end_time=$(date +%s)
echo Executed dev_small benchmark in $((end_time - start_time))s.
