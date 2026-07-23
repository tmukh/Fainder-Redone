#!/usr/bin/env bash
# NUMA validation experiment — 30 min, no code changes.
#
# Tests whether the column-centric 2× regression on 56gb at high t is NUMA-bound
# by running the same workload under 4 numactl configurations:
#
#   A. socket0_only:   48 cores on socket 0, memory pinned to node 0
#   B. socket1_only:   48 cores on socket 1, memory pinned to node 1   (symmetry check)
#   C. interleave_all: 96 cores both sockets, memory pages striped across both nodes
#   D. default:        96 cores both sockets, default first-touch policy
#
# What each tells us:
#   A vs D: if A (48 cores, single socket) ≈ D (96 cores, default), then NUMA
#           crossover is exactly cancelling the doubling of cores.
#   B vs A: symmetry check (should be equal).
#   C vs D: does interleaving help? If yes, default first-touch is biasing
#           pages to one socket.
#
# Output: median wall_s per cell. If any of A/B beats D, NUMA-local mmap is
# the right next implementation step.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
INDEX="/local-data/abumukh/data/gittables/c256_56gb/indices/best_config_rebinning.fidx"
QUERIES="/local-data/abumukh/data/gittables/c256_56gb/queries/all.zst"
OUT="/local-data/abumukh/data/gittables/numa_validation_$(date +%Y%m%d_%H%M).log"
REPEATS=5

cd "$REPO"
source venv/bin/activate

echo "============================================================" | tee -a "$OUT"
echo " NUMA validation — $(date -Iseconds)" | tee -a "$OUT"
echo " Index:   $INDEX" | tee -a "$OUT"
echo " Output:  $OUT" | tee -a "$OUT"
echo "============================================================" | tee -a "$OUT"

# Build default Rust (no features) — column-centric is activated by env var, not feature
echo "[build] cargo --release (default)" | tee -a "$OUT"
maturin develop --release -q 2>&1 | tail -1 | tee -a "$OUT"

# Helper: extract wall_s from runner.py log
parse_wall() {
    grep "Rust index-based query execution time" "$1" | tail -1 | sed -E 's/.*: ([0-9.]+)s.*/\1/'
}

run_cell() {
    local label="$1" numactl_prefix="$2" threads="$3"
    echo "" | tee -a "$OUT"
    echo "=== $label (t=$threads) ===" | tee -a "$OUT"
    local walls=()
    for r in $(seq 1 "$REPEATS"); do
        local logfile="/tmp/numa_${label}_r${r}.log"
        # Pre-warm
        $numactl_prefix \
            env FAINDER_COLUMNAR=1 FAINDER_NUM_THREADS="$threads" FAINDER_SUPPRESS_RESULTS=1 \
            run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall --suppress-results \
                --log-level INFO --log-file "$logfile" >/dev/null 2>&1 || true
        # Measured run
        $numactl_prefix \
            env FAINDER_COLUMNAR=1 FAINDER_NUM_THREADS="$threads" FAINDER_SUPPRESS_RESULTS=1 \
            run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall --suppress-results \
                --log-level INFO --log-file "$logfile" >/dev/null 2>&1
        local w
        w=$(parse_wall "$logfile")
        walls+=("$w")
        printf "  r=%d wall=%ss\n" "$r" "$w" | tee -a "$OUT"
    done
    # Median
    local sorted
    sorted=$(printf '%s\n' "${walls[@]}" | sort -n)
    local n="${#walls[@]}"
    local mid=$((n / 2))
    local median
    median=$(echo "$sorted" | sed -n "$((mid + 1))p")
    echo "  >>> $label median: ${median}s <<<" | tee -a "$OUT"
}

run_cell "A_socket0_only"   "numactl --cpunodebind=0 --membind=0" 48
run_cell "B_socket1_only"   "numactl --cpunodebind=1 --membind=1" 48
run_cell "C_interleave_all" "numactl --interleave=all" 96
run_cell "D_default"        ""  96

echo "" | tee -a "$OUT"
echo "============================================================" | tee -a "$OUT"
echo " NUMA validation complete — $(date -Iseconds)" | tee -a "$OUT"
echo "" | tee -a "$OUT"
echo " VERDICT — compare 'A median' to 'D median':" | tee -a "$OUT"
echo "   A << D: NUMA crossover is killing us. NUMA-local mmap is the right next step." | tee -a "$OUT"
echo "   A ≈ D: cores helped despite NUMA. Bandwidth is the ceiling, not topology." | tee -a "$OUT"
echo "   A >> D: NUMA is fine; something else dominates." | tee -a "$OUT"
echo "============================================================" | tee -a "$OUT"
