#!/usr/bin/env bash
# Main-axes campaign on the new c256_{10,30,56}gb datasets.
#
# Builds × regimes per the methodology in docs/RESULTS.md §1.3:
#   python      — FAINDER_NO_RUST=1 path           with-results (suppress=0)
#   default     — cargo build --release            suppress     (suppress=1)
#   simd        — --features simd                  suppress     (Axis 1)
#   aos         — --features aos                   suppress     (Axis 2)
#   bestofsuite — --features "pooled f16 simd pin-cores cluster-prefetch mimalloc"
#                                                  with-results (end-to-end)
#
# Axis 3 (multicore parallelism) reads off the strong-scaling table of
# `default` across thread counts — no additional build needed.
#
# Sweep: t = 1, 8, 16, 32, 64, 96. Repeats: 5. Median reported in §2/§3.
#
# Order is build-major (build once, sweep all datasets) so we do 4 cargo
# invocations rather than 12. The 56gb fidx may not exist yet when this
# script starts; each dataset's first sweep waits up to 30 min for it.
#
# Output: rows in logs/bench.db with label="main_<size>_<build>_<regime>".

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SWEEP="1,8,16,32,64,96"
REPEATS=5
# Python is GIL-bound — flat across all thread counts (~600s on 10gb at any t).
# So we measure Python at one thread count only, with fewer repeats.
PYTHON_SWEEP="16"
PYTHON_REPEATS=3
# 60-min per-run cap. At t=1 with-results, Python on 56gb is projected ~3000s,
# Rust bestofsuite ~150s. 3600 covers both with margin.
TIMEOUT_S=3600
SIZES=(10gb 30gb 56gb)

cd "$REPO"
source venv/bin/activate

# Per-run timeout: 30 min. Generous because Python with-results at t=1 on
# 56gb may run several minutes per repeat (PyO3 boxing of ~20 GB result set).
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

build_rust() {
    local features="$1"
    if [[ -z "$features" ]]; then
        echo "  [build] cargo --release  (default)"
        maturin develop --release -q 2>&1 | tail -1
    else
        echo "  [build] cargo --release --features \"$features\""
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    fi
}

wait_for_fidx() {
    local fidx="$1"
    if [[ -d "$fidx" ]]; then return 0; fi
    echo "  [wait] $fidx not yet built — polling up to 30 min …"
    for i in $(seq 1 30); do
        sleep 60
        [[ -d "$fidx" ]] && { echo "  [wait] ready after ${i} min"; return 0; }
    done
    echo "  [skip] $fidx still missing after 30 min"
    return 1
}

run_sweep() {
    # build_label, label_for_db, suppress (0/1), index, queries, env_prefix [, sweep, repeats]
    local build="$1" label="$2" suppress="$3" index="$4" queries="$5" env_prefix="$6"
    local sweep="${7:-$SWEEP}" repeats="${8:-$REPEATS}"
    echo
    echo "  ── build=$build  label=$label  suppress=$suppress  sweep=$sweep  reps=$repeats ──"
    eval "$env_prefix FAINDER_SUPPRESS_RESULTS=$suppress \
        scripts/bench.py \
        --build '$build' \
        --sweep '$sweep' \
        --repeats '$repeats' \
        --index '$index' \
        --queries '$queries' \
        --label 'main_${label}' \
        || echo '  [warn] sweep failed (timeout or error) — continuing'"
}

fidx_for() { echo "$DATA_BASE/c256_$1/indices/best_config_rebinning.fidx"; }
queries_for() { echo "$DATA_BASE/c256_$1/queries/all.zst"; }

echo "============================================================"
echo " Main axes campaign — $(date -Iseconds)"
echo " Sweep: $SWEEP   Repeats: $REPEATS"
echo "============================================================"

# ── Phase A: default Rust build (used for Python baseline + Axis 3). ──
build_rust ""
for size in "${SIZES[@]}"; do
    echo
    echo "============== $size — phase A (python + default) =============="
    fidx="$(fidx_for "$size")"
    queries="$(queries_for "$size")"
    wait_for_fidx "$fidx" || continue
    run_sweep "python"  "${size}_python_with"  0 "$fidx" "$queries" "FAINDER_NO_RUST=1" "$PYTHON_SWEEP" "$PYTHON_REPEATS"
    run_sweep "default" "${size}_default_supp" 1 "$fidx" "$queries" ""
done

# ── Phase B: SIMD (Axis 1). ──────────────────────────────────────────
build_rust "simd"
for size in "${SIZES[@]}"; do
    echo
    echo "============== $size — phase B (simd) =============="
    fidx="$(fidx_for "$size")"
    queries="$(queries_for "$size")"
    wait_for_fidx "$fidx" || continue
    run_sweep "simd" "${size}_simd_supp" 1 "$fidx" "$queries" ""
done

# ── Phase C: AoS layout (Axis 2). ────────────────────────────────────
build_rust "aos"
for size in "${SIZES[@]}"; do
    echo
    echo "============== $size — phase C (aos) =============="
    fidx="$(fidx_for "$size")"
    queries="$(queries_for "$size")"
    wait_for_fidx "$fidx" || continue
    run_sweep "aos" "${size}_aos_supp" 1 "$fidx" "$queries" ""
done

# ── Phase D: bestofsuite end-to-end. ─────────────────────────────────
build_rust "pooled f16 simd pin-cores cluster-prefetch mimalloc"
for size in "${SIZES[@]}"; do
    echo
    echo "============== $size — phase D (bestofsuite, with-results) =============="
    fidx="$(fidx_for "$size")"
    queries="$(queries_for "$size")"
    wait_for_fidx "$fidx" || continue
    run_sweep "bestofsuite" "${size}_bestofsuite_with" 0 "$fidx" "$queries" ""
done

echo
echo "============================================================"
echo " Main axes campaign complete — $(date -Iseconds)"
echo "============================================================"
echo "Run scripts/main_axes_report.py to populate docs/RESULTS.md tables."
