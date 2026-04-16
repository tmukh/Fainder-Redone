#!/bin/bash
# Launches all ablation experiments in parallel tmux sessions.
# A monitor session waits for all four to finish, then writes EXPERIMENT_RESULTS.md.
#
# Prerequisites (run manually first):
#   source venv/bin/activate && maturin develop --release
#
# Usage:
#   bash scripts/launch_tmux_experiments.sh

set -euo pipefail
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$ROOT"

VENV="$ROOT/venv/bin/activate"
DONE_DIR="/tmp/fainder_done"
mkdir -p "$DONE_DIR"
rm -f "$DONE_DIR"/*.done   # clear stale markers

SESSIONS=(baseline-medium baseline-10gb ablation-small ablation-medium)

# Kill any pre-existing sessions with the same names
for s in "${SESSIONS[@]}" fainder-monitor; do
    tmux kill-session -t "$s" 2>/dev/null || true
done

echo "Launching 4 experiment sessions..."

tmux new-session -d -s baseline-medium \
    "source '$VENV' && \
     bash '$ROOT/scripts/baseline_comparison.sh' eval_medium 2>&1 | tee /tmp/baseline_medium.log; \
     touch '$DONE_DIR/baseline-medium.done'; \
     echo 'baseline-medium DONE'"

tmux new-session -d -s baseline-10gb \
    "source '$VENV' && \
     bash '$ROOT/scripts/baseline_comparison.sh' eval_10gb 2>&1 | tee /tmp/baseline_10gb.log; \
     touch '$DONE_DIR/baseline-10gb.done'; \
     echo 'baseline-10gb DONE'"

tmux new-session -d -s ablation-small \
    "source '$VENV' && \
     bash '$ROOT/scripts/ablation_parallel.sh' dev_small 2>&1 | tee /tmp/ablation_small.log; \
     touch '$DONE_DIR/ablation-small.done'; \
     echo 'ablation-small DONE'"

tmux new-session -d -s ablation-medium \
    "source '$VENV' && \
     bash '$ROOT/scripts/ablation_parallel.sh' eval_medium 2>&1 | tee /tmp/ablation_medium.log; \
     touch '$DONE_DIR/ablation-medium.done'; \
     echo 'ablation-medium DONE'"

# Monitor session: waits for all four .done markers, then collects results
tmux new-session -d -s fainder-monitor \
    "echo 'Monitor: waiting for all sessions to finish...'
     until [ -f '$DONE_DIR/baseline-medium.done' ] && \
           [ -f '$DONE_DIR/baseline-10gb.done' ] && \
           [ -f '$DONE_DIR/ablation-small.done' ] && \
           [ -f '$DONE_DIR/ablation-medium.done' ]; do
         echo \"\$(date '+%H:%M') — waiting... done: \$(ls '$DONE_DIR'/*.done 2>/dev/null | wc -l)/4\"
         sleep 120
     done
     echo 'All sessions done. Collecting results...'
     source '$VENV'
     cd '$ROOT'
     bash scripts/collect_results.sh
     echo ''
     echo '=============================='
     echo 'EXPERIMENT_RESULTS.md written!'
     echo '=============================='
     cat EXPERIMENT_RESULTS.md"

echo ""
echo "Sessions started:"
printf "  %-22s  %s\n" "tmux attach -t baseline-medium"  "baseline comparison on eval_medium   (~3-5h)"
printf "  %-22s  %s\n" "tmux attach -t baseline-10gb"    "baseline comparison on eval_10gb     (~2-4h)"
printf "  %-22s  %s\n" "tmux attach -t ablation-small"   "thread sweep on dev_small            (~30-60min)"
printf "  %-22s  %s\n" "tmux attach -t ablation-medium"  "thread sweep on eval_medium          (~4-8h)"
printf "  %-22s  %s\n" "tmux attach -t fainder-monitor"  "waits for all → writes EXPERIMENT_RESULTS.md"
echo ""
echo "Monitor live logs:"
echo "  tail -f /tmp/baseline_medium.log /tmp/baseline_10gb.log"
echo "  tail -f /tmp/ablation_small.log /tmp/ablation_medium.log"
echo ""
echo "Results will be written to: $ROOT/EXPERIMENT_RESULTS.md"
