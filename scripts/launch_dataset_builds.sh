#!/usr/bin/env bash
# Launch all 3 dataset builds in separate tmux sessions, in parallel.
#
# Sessions:
#   build10  — c256_10gb (re-cluster eval_10gb histograms; ~30–60 min)
#   build30  — c256_30gb (re-cluster eval_medium histograms; ~1–2 h)
#   build56  — c256_56gb (full pipeline from pq/; ~5–7 h)
#
# Workers are staggered (32/48/96) so all three coexist on the 96-core box
# without thrashing.

set -euo pipefail

REPO="/home/abumukh-ldap/fainder-redone"
DRIVER="$REPO/scripts/build_dataset.sh"

start_one() {
    local size="$1"
    local sess="build${size%gb}"
    if tmux has-session -t "$sess" 2>/dev/null; then
        echo "tmux session '$sess' already exists — skipping (kill it first if you want a fresh start)"
        return
    fi
    echo "Starting tmux session '$sess' for $size"
    tmux new-session -d -s "$sess" \
        "cd $REPO && bash $DRIVER $size 2>&1 | tee /local-data/abumukh/data/gittables/c256_${size}_build.log; \
         echo; echo '=== build done — press any key to exit ==='; read -n 1"
}

start_one 10gb
start_one 30gb
start_one 56gb

echo
echo "All three sessions launched. Attach with:"
echo "  tmux attach -t build10"
echo "  tmux attach -t build30"
echo "  tmux attach -t build56"
echo
tmux ls
