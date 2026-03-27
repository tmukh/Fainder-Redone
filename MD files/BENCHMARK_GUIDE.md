# Fainder Benchmark Guide
This guide details how to run the three variations of Fainder query execution for performance comparison.

## Prerequisites
- Activate the virtual environment: `source .venv/bin/activate` (or ensure you are using the venv python).
- Ensure `PYTHONPATH` includes the current directory: `export PYTHONPATH=$PYTHONPATH:.`
- Build the Rust extension: `maturin develop --release` (if not already done).

## 1. Baseline (Iterative Search)
This approach iterates over histograms in Python without using the index. It provides the "slow" baseline.

```bash
run-queries \
    -i data/eval_medium/histograms.zst \
    -t histograms \
    -q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
    -e over \
    --workers 4 \
    --log-file logs/benchmark_baseline.log
```

## 2. Fainder (Python Index)
This runs the original Python-based index implementation. We disable the Rust backend explicitly.

```bash
FAINDER_NO_RUST=1 run-queries \
    -i data/eval_medium/indices/best_config_rebinning.zst \
    -t index \
    -q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
    -m recall \
    --workers 4 \
    --log-file logs/benchmark_python.log
```

## 3. Fainder (Rust Index - Optimized)
This runs the new high-performance Rust backend using `fainder_core`. It uses the SoA memory layout and Rayon-based parallelism.

```bash
# Note: No environment variable needed; Rust is used by default if available.
run-queries \
    -i data/eval_medium/indices/best_config_rebinning.zst \
    -t index \
    -q data/gittables/queries/accuracy_benchmark_eval_medium/all.zst \
    -m recall \
    --workers 4 \
    --log-file logs/benchmark_rust.log
```

## Checking Results
Inspect the logs for "execution_time" or "Ran X queries in Ys".

```bash
tail -n 5 logs/benchmark_*.log
```

**Note**: For `eval_large` (1GB or 10GB), replace `eval_medium` paths with `eval_large`.
