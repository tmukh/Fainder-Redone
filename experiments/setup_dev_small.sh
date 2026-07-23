#!/bin/bash

echo "Executing setup for dev_small"

set -euxo pipefail
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
start_time=$(date +%s)
log_level=INFO
nproc=$(nproc)

pwd
ls -ld data/gittables/dev_small

# 1. Compute Histograms and Distributions
# Note: Data is already in data/gittables/dev_small (copied from pq)
compute-histograms -i data/gittables/dev_small -o data/gittables/dev_small_histograms.zst --bin-range 10 20
compute-distributions -i data/gittables/dev_small -o data/gittables/dev_small_normal_dists.zst -k normal

# 2. Cluster Histograms (Index Configuration)
# Use smaller k for small dataset (k=10 instead of 750)
cluster-histograms \
    -i data/gittables/dev_small_histograms.zst \
    -o data/gittables/dev_small_clustering.zst \
    -a kmeans \
    -c 10 10 \
    -b 1000 \
    -t quantile \
    --alpha 1 \
    --seed 42 \
    --log-level "$log_level"

# 3. Generate Benchmark Queries
# Create query directory
mkdir -p data/gittables/queries/accuracy_benchmark_dev_small

generate-queries -o data/gittables/queries/accuracy_benchmark_dev_small/all.zst \
    --n-percentiles 10 \
    --n-reference-values 10 \
    --seed 42 \
    --reference-value-range "-10000" "10000"

# 4. Collate Queries (Process against ground truth)
# NOTE: This relies on the user's edit to collate_benchmark_queries.py to accept 'dev_small'
# But since the script structures paths as data/{dataset}/..., and we are hacking it a bit,
# we might need to be careful.
# The script expects: data/{dataset}/histograms.zst
# My histograms are at: data/gittables/dev_small_histograms.zst
# This assumes I passed -d dev_small.
# If I pass -d dev_small, it looks for data/dev_small/histograms.zst
# So I should PROBABLY ensure the directory structure matches what the script expects,
# or simply symlink things.

# Let's align with the script's expectation: data/{dataset}/...
# I will move/symlink my dev_small data to be a top-level "dataset" for the purpose of the tools.
mkdir -p data/dev_small
ln -sf $(pwd)/data/gittables/dev_small_histograms.zst data/dev_small/histograms.zst

# Now run collation
python experiments/collate_benchmark_queries.py \
    -d dev_small \
    -q data/gittables/queries/accuracy_benchmark_dev_small/all.zst \
    -c data/gittables/dev_small_clustering.zst \
    -w "$nproc" \
    --log-level "$log_level"

# 5. Create Index
create-index \
    -i data/gittables/dev_small_clustering.zst \
    -m rebinning \
    -p float32 \
    -o data/dev_small/indices \
    --index-file best_config_rebinning.zst \
    --log-level "$log_level"

end_time=$(date +%s)
echo Executed setup in $((end_time - start_time))s.
