#!/bin/bash

echo "Executing setup for eval_medium"

set -euxo pipefail
ulimit -Sn 10000
cd "$(git rev-parse --show-toplevel)"
start_time=$(date +%s)
log_level=INFO
nproc=$(nproc)

pwd
ls -ld data/gittables/eval_medium

# 1. Compute Histograms and Distributions
# Note: Data is already in data/gittables/eval_medium (copied from pq)
compute-histograms -i data/gittables/eval_medium -o data/gittables/eval_medium_histograms.zst --bin-range 10 20
compute-distributions -i data/gittables/eval_medium -o data/gittables/eval_medium_normal_dists.zst -k normal

# 2. Cluster Histograms (Index Configuration)
# Use larger k for medium dataset (k=50)
cluster-histograms \
    -i data/gittables/eval_medium_histograms.zst \
    -o data/gittables/eval_medium_clustering.zst \
    -a kmeans \
    -c 50 50 \
    -b 5000 \
    -t quantile \
    --alpha 1 \
    --seed 42 \
    --log-level "$log_level"

# 3. Generate Benchmark Queries
# Create query directory
mkdir -p data/gittables/queries/accuracy_benchmark_eval_medium

generate-queries -o data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
    --n-percentiles 20 \
    --n-reference-values 10 \
    --seed 42 \
    --reference-value-range "-10000" "10000"

# 4. Collate Queries (Process against ground truth)
# Create valid "dataset" directory structure for the script
mkdir -p data/eval_medium
ln -sf $(pwd)/data/gittables/eval_medium_histograms.zst data/eval_medium/histograms.zst

# Run collation
python experiments/collate_benchmark_queries.py \
    -d eval_medium \
    -q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
    -c data/gittables/eval_medium_clustering.zst \
    -w "$nproc" \
    --log-level "$log_level"

# 5. Create Index
create-index \
    -i data/gittables/eval_medium_clustering.zst \
    -m rebinning \
    -p float32 \
    -o data/eval_medium/indices \
    --index-file best_config_rebinning.zst \
    --log-level "$log_level"

end_time=$(date +%s)
echo Executed setup in $((end_time - start_time))s.
