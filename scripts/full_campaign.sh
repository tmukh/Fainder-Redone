#!/usr/bin/env bash
# Full ablation campaign on the post-corrected-code Fainder Rust port.
#
# WHAT IT DOES
#   For each (build label, --features, env override) tuple in CONFIGS:
#     1. maturin develop --release with the requested features
#     2. Run a thread sweep (1, 8, 16, 32, 64, 96) under FAINDER_SUPPRESS_RESULTS=1
#        (the search-phase isolation regime, primary)
#     3. Run the same sweep under FAINDER_SUPPRESS_RESULTS=0
#        (the with-results regime, secondary — for the |S| ceiling story)
#   Each (config, thread, mode) is repeated 3× and rows land in logs/bench.db
#   tagged with --label="campaign_supp" or --label="campaign_with".
#
# CONFIGS COVERED
#   14 singleton ablations (one optimization isolated each):
#     default · columnar · aos · f16 · simd · horizontal-simd · batch-search
#     kary · eytzinger · pooled · mimalloc · pin-cores · pooled-prefetch · f16-simd
#   5 combined-progression points (cumulative speedup story):
#     pooled-f16 → +simd → +pin-cores → +cluster-prefetch → +mimalloc (=bestofsuite)
#   = 19 builds × 6 threads × 2 modes × 3 reps = 684 runs.
#
# NOT INCLUDED
#   Python baseline (separate, much slower; rerun via scripts/bench_python_only.sh
#   if/when needed).
#
# ETA: ~2 hours. Run via tmux.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
INDEX="/local-data/abumukh/data/gittables/eval_medium/indices/best_config_rebinning.fidx"
QUERIES="/local-data/abumukh/data/gittables/eval_medium/queries/all.zst"
THREADS_SWEEP="1,8,16,32,64,96"
REPEATS=3

# Per-run timeout: 1800s (30 min). With-results at t=1 on the f16 path can
# legitimately take 10+ minutes due to PyO3 conversion of a 20+ GB result set.
export FAINDER_BENCH_TIMEOUT_S=1800

cd "$REPO"
source venv/bin/activate

echo "============================================================"
echo " Full campaign — corrected-code re-baseline"
echo " Index:   $INDEX"
echo " Queries: $QUERIES"
echo " Threads: $THREADS_SWEEP"
echo " Repeats: $REPEATS"
echo " Started: $(date -Iseconds)"
echo "============================================================"

run_config() {
    local label="$1"
    local features="$2"
    local extra_env="$3"

    echo
    echo "============================================================"
    echo " BUILD: $label"
    echo "        features=\"$features\""
    [[ -n "$extra_env" ]] && echo "        env=\"$extra_env\""
    echo "============================================================"

    if [[ -z "$features" ]]; then
        maturin develop --release -q 2>&1 | tail -1
    else
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    fi

    for suppress in 1 0; do
        local mode_label="supp"
        [[ "$suppress" == "0" ]] && mode_label="with"

        echo
        echo "--- $label / $mode_label-results / sweep $THREADS_SWEEP / $REPEATS reps ---"

        # env -i would wipe inherited env; we want to keep PATH, venv, etc.
        # so we just prefix the relevant vars.
        if [[ -z "$extra_env" ]]; then
            FAINDER_SUPPRESS_RESULTS="$suppress" \
                scripts/bench.py \
                    --build "$label" \
                    --sweep "$THREADS_SWEEP" \
                    --repeats "$REPEATS" \
                    --index "$INDEX" --queries "$QUERIES" \
                    --label "campaign_${mode_label}"
        else
            env $extra_env FAINDER_SUPPRESS_RESULTS="$suppress" \
                scripts/bench.py \
                    --build "$label" \
                    --sweep "$THREADS_SWEEP" \
                    --repeats "$REPEATS" \
                    --index "$INDEX" --queries "$QUERIES" \
                    --label "campaign_${mode_label}"
        fi
    done
}

# ── Singleton ablations (each isolating one axis) ──────────────────────────
run_config "default"             ""                  ""
run_config "columnar"            ""                  "FAINDER_COLUMNAR=1"
run_config "aos"                 "aos"               ""
run_config "f16"                 "f16"               ""
run_config "simd"                "simd"              ""
run_config "horizontal-simd"     "horizontal-simd"   "FAINDER_COLUMNAR=1"
run_config "batch-search"        "batch-search"      "FAINDER_COLUMNAR=1"
run_config "kary"                "kary"              ""
run_config "eytzinger"           "eytzinger"         ""
run_config "pooled"              "pooled"            ""
run_config "mimalloc"            "mimalloc"          ""
run_config "pin-cores"           "pin-cores"         ""
run_config "pooled-prefetch"     "pooled cluster-prefetch" ""
# NEW: AVX-512 f16 final stage via u16-bitcast trick (added this session)
run_config "f16-simd"            "f16 simd"          ""

# ── Combined progression (cumulative speedup story) ────────────────────────
run_config "pooled-f16"                       "pooled f16"                                    ""
run_config "pooled-f16-simd"                  "pooled f16 simd"                               ""
run_config "pooled-f16-simd-pin"              "pooled f16 simd pin-cores"                     ""
run_config "pooled-f16-simd-pin-prefetch"     "pooled f16 simd pin-cores cluster-prefetch"    ""
run_config "bestofsuite"                      "pooled f16 simd pin-cores cluster-prefetch mimalloc" ""

echo
echo "============================================================"
echo " Campaign complete — $(date -Iseconds)"
echo "============================================================"
python3 "$REPO/scripts/full_campaign_report.py"
