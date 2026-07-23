#!/usr/bin/env bash
# Mechanism-disambiguation probe per cowork: 56gb t=32, single rep per
# build, with the perf counters that distinguish:
#   - dTLB pressure  (dtlb_load_misses.walk_completed, dTLB-load-misses)
#   - NUMA cross-socket fetch  (LLC-loads, LLC-load-misses, miss%)
#   - split cache-line loads from bw=13 cross-word reads
#     (mem_inst_retired.split_loads)
#
# Hypothesis lattice (cowork):
#   H1 (TLB): dTLB walks ↑ on local-ids* vs packed-ids
#   H2 (NUMA): LLC-loads ↑ but miss% normal
#   H3 (split-loads): bw=13 decode produces more split cache-line accesses
#
# local-ids-noalloc is the pivot: same decoder as local-ids-bench but
# without local_to_global resident. If noalloc still regresses → not table
# allocation; mechanism is in the decoder itself (H3 most likely).

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DATA_BASE="/local-data/abumukh/data/gittables"
SIZE="56gb"
THREADS="${THREADS:-32}"
INDEX="$DATA_BASE/c256_$SIZE/indices/best_config_rebinning.fidx"
QUERIES="$DATA_BASE/c256_$SIZE/queries/all.zst"

PERF_EVENTS="cycles,instructions,LLC-load-misses,dTLB-load-misses,cpu/event=0xd0,umask=0x41,name=mem_split_loads/"

cd "$REPO"
source venv/bin/activate

probe_one () {
    local features="$1"
    local label="$2"
    echo
    echo "=========== $label (--features '${features:-default}') ==========="
    if [[ -n "$features" ]]; then
        maturin develop --release --features "$features" -q 2>&1 | tail -1
    else
        maturin develop --release -q 2>&1 | tail -1
    fi
    FAINDER_NUM_THREADS=$THREADS perf stat -e "$PERF_EVENTS" -- \
        run-queries -i "$INDEX" -t index -q "$QUERIES" -m recall \
        --suppress-results --log-level INFO 2>&1 | grep -E "Ran 10000|cycles|instructions|LLC-|dTLB-|dtlb_|split_loads"
}

echo "============================================================"
echo " mechanism probe: 56gb t=$THREADS, $(date -Iseconds)"
echo "============================================================"

probe_one ""                    "default"
probe_one "packed-ids"          "packed-ids (baseline win)"
probe_one "local-ids"           "local-ids (option 1, regression with lookup)"
probe_one "local-ids-bench"     "local-ids-bench (option 4, regression no-lookup)"
probe_one "local-ids-noalloc"   "local-ids-noalloc (decoder-only, table NOT resident)"

echo
echo "============================================================"
echo " probe complete — $(date -Iseconds)"
echo "============================================================"
