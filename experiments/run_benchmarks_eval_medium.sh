#!/bin/bash

echo "Executing runtime benchmark for eval_medium with profiling"

set -euxo pipefail
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
start_time=$(date +%s)

# Define paths
DATA_DIR="data/eval_medium"
QUERIES_SRC="data/gittables/queries/accuracy_benchmark_eval_medium/all.zst"
INDEX="data/eval_medium/indices/best_config_rebinning.zst"
HISTOGRAMS="data/eval_medium/histograms.zst"

# Create log directory
mkdir -p logs/eval_medium_benchmark

# Single Query to Profile
QUERY_ARGS=("0.1" "lt" "50")

# 1. Performance - Baseline (Iterative)
echo "Running baseline..."
run-query \
    -i "$HISTOGRAMS" \
    -t histograms \
    -q "${QUERY_ARGS[@]}" \
    -e over \
    --log-file logs/eval_medium_benchmark/query-iterative.log

# 2. Performance - Index (Rebinning)
echo "Running fainder index..."
run-query \
    -i "$INDEX" \
    -t index \
    -q "${QUERY_ARGS[@]}" \
    -m recall \
    --log-file logs/eval_medium_benchmark/query-rebinning.log


# 3. Profiling - Python cProfile
# Profile the Index execution to find Python hotspots
echo "Running cProfile..."
python -m cProfile -o logs/eval_medium_benchmark/profile.pstats \
    -m fainder.execution.runner_single \
    -i "$INDEX" \
    -t index \
    -q "${QUERY_ARGS[@]}" \
    -m recall \
    --log-file logs/eval_medium_benchmark/query-rebinning-profile.log

# Dump stats to text
echo "Dumping cProfile stats..."
python -c "import pstats; p = pstats.Stats('logs/eval_medium_benchmark/profile.pstats'); p.sort_stats('cumulative').print_stats(20)" \
    > logs/eval_medium_benchmark/profile_stats.txt


# 4. Profiling - perf (CPU Counters)
# Count cycles, instructions, cache-misses
echo "Running perf stat..."
perf stat \
    -e cycles,instructions,cache-references,cache-misses,branches,branch-misses \
    -o logs/eval_medium_benchmark/perf_stat.txt \
    python -m fainder.execution.runner_single \
    -i "$INDEX" \
    -t index \
    -q "${QUERY_ARGS[@]}" \
    -m recall \
    --log-file logs/eval_medium_benchmark/query-rebinning-perf.log


# 5. Profiling - valgrind (Callgrind)
# Detailed call graph analysis
# Note: This is very slow, run only on single query
echo "Running valgrind (callgrind)..."
valgrind --tool=callgrind \
    --callgrind-out-file=logs/eval_medium_benchmark/callgrind.out \
    python -m fainder.execution.runner_single \
    -i "$INDEX" \
    -t index \
    -q "${QUERY_ARGS[@]}" \
    -m recall \
    --log-file logs/eval_medium_benchmark/query-rebinning-valgrind.log

end_time=$(date +%s)
echo Executed eval_medium benchmark in $((end_time - start_time))s.
