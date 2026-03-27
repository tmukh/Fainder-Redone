#!/bin/bash

# EVAL_MEDIUM PIPELINE PROGRESS MONITOR
# =====================================

echo "╔════════════════════════════════════════════╗"
echo "║  EVAL_MEDIUM PIPELINE PROGRESS MONITOR    ║"
echo "╚════════════════════════════════════════════╝"
echo ""
echo "Time: $(date)"
echo ""

echo "📊 PIPELINE STATUS"
echo "=================="
ps aux | grep "setup_gittables_minimal\|collate_benchmark\|create-index\|compute-histograms\|cluster-histograms" | grep -v grep | awk '{print $11, $12, $13, $14, $15}' || echo "No processes found"

echo ""
echo "📁 DATA DIRECTORY SIZES"
echo "======================="
echo ""
echo "dev_small (completed):"
du -sh /local-data/abumukh/data/gittables/dev_small/ 2>/dev/null || echo "  Not found"

echo ""
echo "eval_medium (in progress):"
du -sh /local-data/abumukh/data/gittables/eval_medium/ 2>/dev/null || echo "  Not started"

echo ""
echo "📈 RECENT LOG UPDATES (Last 30 lines)"
echo "===================================="
tail -30 /tmp/eval_medium_pipeline.log 2>/dev/null || echo "Log file not ready yet"

echo ""
echo "💾 DISK USAGE"
echo "============="
df -h /local-data/abumukh/data/gittables/ | tail -1 | awk '{print "Total: " $2 ", Used: " $3 ", Available: " $4}'

echo ""
echo "⏱️  ELAPSED TIME"
echo "==============="
if [ -f /tmp/eval_medium_pipeline.log ]; then
  start_line=$(head -1 /tmp/eval_medium_pipeline.log 2>/dev/null | grep -oE "Started:|+" | head -1)
  echo "Check log for start time: tail -1 /tmp/eval_medium_pipeline.log"
fi

echo ""
echo "📝 TO MONITOR LIVE:"
echo "=================="
echo "  tail -f /tmp/eval_medium_pipeline.log"
echo ""
echo "📊 TO CHECK SPECIFIC STEP:"
echo "=========================="
echo "  grep -E 'Parsed|Clustered|Generated' /tmp/eval_medium_pipeline.log"
echo ""
echo "🎯 EXPECTED TIMELINE"
echo "==================="
echo "  1. Histograms (20% sample): ~10-15 min"
echo "  2. Distributions: ~30-45 min"
echo "  3. Clustering (K=100): ~1-2 hours"
echo "  4. Query generation: ~1 min"
echo "  5. Query collation: ~30-60 min"
echo "  6. Index creation: ~5-10 min"
echo "  7. Python benchmark: ~1-5 min"
echo "  8. Rust benchmark: ~0.1-0.5 min"
echo "  ────────────────────────"
echo "  TOTAL: ~18-34 hours"
echo ""
