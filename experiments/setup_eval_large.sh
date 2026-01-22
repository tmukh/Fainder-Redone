#!/bin/bash

echo "Executing setup for eval_large"

set -euxo pipefail
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
start_time=$(date +%s)
log_level=INFO
nproc=$(nproc)

pwd
# ls -ld data/gittables/eval_large # Too many files to list effectively

# 1. Compute Histograms and Distributions
# Note: Data is already in data/gittables/eval_large (copied from pq)
compute-histograms -i data/gittables/eval_large -o data/gittables/eval_large_histograms.zst --bin-range 10 20
compute-distributions -i data/gittables/eval_large -o data/gittables/eval_large_normal_dists.zst -k normal

# 2. Cluster Histograms (Index Configuration)
# Use larger k for large dataset (k=500)
cluster-histograms \
    -i data/gittables/eval_large_histograms.zst \
    -o data/gittables/eval_large_clustering.zst \
    -a kmeans \
    -c 250 250 \
    -b 10000 \
    -t quantile \
    --alpha 1 \
    --seed 42 \
    --log-level "$log_level"

# 3. Generate Benchmark Queries
# Create query directory
mkdir -p data/gittables/queries/accuracy_benchmark_eval_large

generate-queries -o data/gittables/queries/accuracy_benchmark_eval_large/all.zst \
    --n-percentiles 20 \
    --n-reference-values 10 \
    --seed 42 \
    --reference-value-range "-10000" "10000"

# 4. Collate Queries (Process against ground truth)
# Create valid "dataset" directory structure for the script
mkdir -p data/eval_large
ln -sf $(pwd)/data/gittables/eval_large_histograms.zst data/eval_large/histograms.zst

# Run collation
python experiments/collate_benchmark_queries.py \
    -d eval_large \
    -q data/gittables/queries/accuracy_benchmark_eval_large/all.zst \
    -c data/gittables/eval_large_clustering.zst \
    -w "$nproc" \
    --log-level "$log_level"

# 5. Create Index
create-index \
    -i data/gittables/eval_large_clustering.zst \
    -m rebinning \
    -p float32 \
    -o data/eval_large/indices \
    --index-file best_config_rebinning.zst \
    --log-level "$log_level"

end_time=$(date +%s)
echo Executed setup in $((end_time - start_time))s.
