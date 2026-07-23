#!/usr/bin/env bash
# NUMA-placement probe — does cross-socket interconnect hide as a separate
# ceiling inside §3.7/§3.8's "DRAM bandwidth"?
#
# Sapphire Rapids 8468H is 2-socket (NUMA node 0 = socket 0, node 1 =
# socket 1). Aggregate DDR5 is ~600 GB/s; per-socket ~300 GB/s with
# cross-socket UPI bottleneck. §3.7/§3.8 lumps "DRAM bandwidth" into one
# ceiling — this probe asks whether explicit memory binding moves the
# wall enough to split it into two ceilings.
#
# Configurations (all on c256_56gb, packed-ids build, 5 reps each):
#   A. unpinned (current first-touch) at t=32/48/64/96   [bench.db has 32/64/96]
#   B. single-socket-clean (numactl --cpunodebind=0 --membind=0) at t=32/48
#   C. interleave (numactl --interleave=0,1) at t=32/48/64/96
#   D. cross-socket-forced (mem on node 0, CPU on node 1) at t=32/48
#
# Outcomes that move the thesis:
#   * (B) much faster than (A) at matched t: opens a 4th ceiling
#     (cross-socket interconnect), expands §3.8's two-ceiling model.
#   * (B) ~= (A): reinforces single-bandwidth-ceiling reading; a
#     positive numa intervention does not bind. 5th instance of
#     negative-composability on the memory-locality axis.
#   * (D) catastrophic vs (B): confirms cross-socket is a separate
#     mechanism even if (B) ~= (A) on the dispatch cells.
#
# Pattern follows scripts/run_*.sh.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="56gb"
REPEATS=5
TIMEOUT_S=3600

cd "$REPO"
source venv/bin/activate
export FAINDER_BENCH_TIMEOUT_S="$TIMEOUT_S"

fidx="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
queries="$DATA_BASE/c256_$SIZE/queries/all.zst"

echo "============================================================"
echo " NUMA probe — c256_$SIZE, packed-ids, $(date -Iseconds)"
echo "============================================================"

echo
echo "[build] cargo --release --features packed-ids"
maturin develop --release --features packed-ids -q 2>&1 | tail -1

# Helper: run one NUMA configuration across selected thread counts.
run_numa () {
    local prefix="$1"
    local threads="$2"
    local label_suffix="$3"
    local build_tag="$4"
    echo
    echo "  --- config: prefix='${prefix:-none}' threads=$threads tag=$build_tag ---"
    FAINDER_BENCH_PREFIX="$prefix" scripts/bench.py \
        --build "$build_tag" \
        --sweep "$threads" \
        --repeats "$REPEATS" \
        --index "$fidx" \
        --queries "$queries" \
        --label "numa_${SIZE}_${label_suffix}_supp" \
        || echo "  [warn] $build_tag failed"
}

# Sapphire Rapids 8468H NUMA topology:
#   node 0 cpus: 0-47, 96-143  (physical 0-47, HT 96-143)
#   node 1 cpus: 48-95, 144-191 (physical 48-95, HT 144-191)
# We use physical-core ranges (0-47, 48-95) for cross-socket-forced
# probes since HT contention is its own confound (§3.8).

# B. Single-socket-clean: memory + CPU both on node 0.
echo
echo "=========== B: single-socket-clean (node 0) ==========="
run_numa "numactl --cpunodebind=0 --membind=0" 32 "single_socket_b" "numa_packed_ids_B"
run_numa "numactl --cpunodebind=0 --membind=0" 48 "single_socket_b" "numa_packed_ids_B"

# C. Interleave memory pages across both nodes.
echo
echo "=========== C: interleave both nodes ==========="
run_numa "numactl --interleave=0,1" 32 "interleave_c" "numa_packed_ids_C"
run_numa "numactl --interleave=0,1" 48 "interleave_c" "numa_packed_ids_C"
run_numa "numactl --interleave=0,1" 64 "interleave_c" "numa_packed_ids_C"
run_numa "numactl --interleave=0,1" 96 "interleave_c" "numa_packed_ids_C"

# D. Cross-socket-forced: memory on node 0, CPUs forced to node 1 physical cores.
echo
echo "=========== D: cross-socket-forced (mem=0, cpu=1) ==========="
run_numa "numactl --membind=0 --physcpubind=48-79" 32 "cross_socket_d" "numa_packed_ids_D"
run_numa "numactl --membind=0 --physcpubind=48-95" 48 "cross_socket_d" "numa_packed_ids_D"

# A baseline is already in bench.db (main_56gb_packed_ids_supp). To make the
# probe analysis self-contained, re-run baseline t=48 (we don't have it
# previously) and capture a fresh unpinned t=32/64 for paired comparison.
echo
echo "=========== A: unpinned baseline (paired re-run) ==========="
run_numa "" 32 "unpinned_a" "numa_packed_ids_A"
run_numa "" 48 "unpinned_a" "numa_packed_ids_A"
run_numa "" 64 "unpinned_a" "numa_packed_ids_A"
run_numa "" 96 "unpinned_a" "numa_packed_ids_A"

echo
echo "============================================================"
echo " NUMA probe complete — $(date -Iseconds)"
echo "============================================================"
