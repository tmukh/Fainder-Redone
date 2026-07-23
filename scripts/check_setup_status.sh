#!/bin/bash

# FAINDER DATA & SETUP STATUS CHECKER
# ===================================
# Quick diagnostic to show what's ready and what needs to be set up

echo "======================================"
echo "FAINDER DATA SETUP STATUS CHECK"
echo "======================================"
echo ""

# Check CLI tools
echo "1. CLI TOOLS STATUS:"
echo "   Checking if Fainder CLI is installed..."

tools=(
  "compute-histograms"
  "cluster-histograms"
  "create-index"
  "run-queries"
)

all_found=true
for tool in "${tools[@]}"; do
  if command -v "$tool" &> /dev/null; then
    echo "   ✓ $tool"
  else
    echo "   ✗ $tool (MISSING)"
    all_found=false
  fi
done

if [ "$all_found" = false ]; then
  echo ""
  echo "   To install CLI tools, run:"
  echo "     pip install -e ."
  echo "     maturin develop --release"
  echo ""
fi

# Check input data
echo ""
echo "2. INPUT DATA STATUS:"
if [ -d "/local-data/abumukh/data/gittables/pq" ]; then
  num_files=$(ls /local-data/abumukh/data/gittables/pq/*.pq 2>/dev/null | wc -l)
  total_size=$(du -sh /local-data/abumukh/data/gittables/pq 2>/dev/null | cut -f1)
  echo "   ✓ GitTables parquet files found"
  echo "     Files: $num_files parquet files"
  echo "     Size: $total_size"
else
  echo "   ✗ GitTables parquet files NOT found at /local-data/abumukh/data/gittables/pq"
fi

# Check existing processed data
echo ""
echo "3. PROCESSED DATA STATUS:"

check_dataset() {
  local dataset=$1
  local path="data/$dataset"

  if [ -d "$path" ]; then
    local size=$(du -sh "$path" 2>/dev/null | cut -f1)
    local hist_exists=$([ -f "$path/histograms.zst" ] && echo "yes" || echo "no")
    local idx_exists=$([ -f "$path/indices/best_config_rebinning.zst" ] && echo "yes" || echo "no")

    echo "   Dataset: $dataset ($size)"
    echo "     Histograms: $hist_exists"
    echo "     Index: $idx_exists"
  fi
}

check_dataset "dev_small"
check_dataset "eval_small"
check_dataset "eval_medium"
check_dataset "eval_large"

# Check disk space
echo ""
echo "4. DISK SPACE STATUS:"
available=$(df -h /home/abumukh-ldap/fainder-redone | tail -1 | awk '{print $4}')
used=$(df -h /home/abumukh-ldap/fainder-redone | tail -1 | awk '{print $3}')
total=$(df -h /home/abumukh-ldap/fainder-redone | tail -1 | awk '{print $2}')

echo "   Total: $total"
echo "   Used: $used"
echo "   Available: $available"

# Recommend minimum space
echo ""
echo "5. SPACE REQUIREMENTS:"
echo "   dev_small         ~500MB"
echo "   eval_small        ~2GB"
echo "   eval_medium       ~10GB"
echo "   eval_large        ~50GB"

# Next steps
echo ""
echo "======================================"
echo "RECOMMENDED NEXT STEPS:"
echo "======================================"
echo ""

if [ "$all_found" = false ]; then
  echo "1. Install CLI tools:"
  echo "   cd /home/abumukh-ldap/fainder-redone"
  echo "   pip install -e ."
  echo "   maturin develop --release"
  echo ""
fi

echo "2. Choose setup size and run:"
echo ""
echo "   QUICK TEST (2-3 hours, ~500MB):"
echo "     bash experiments/setup_gittables_minimal.sh dev_small"
echo ""
echo "   SMALL EVAL (4-6 hours, ~2GB):"
echo "     bash experiments/setup_gittables_minimal.sh eval_small"
echo ""
echo "   MEDIUM EVAL (20-30 hours, ~10GB):"
echo "     bash experiments/setup_gittables_minimal.sh eval_medium"
echo ""
echo "3. Monitor progress:"
echo "     tail -f FAINDER_*.log"
echo ""
echo "4. After setup, run benchmarks:"
echo "     time run-queries -i data/dev_small/indices/best_config_rebinning.zst \\"
echo "       -t index -q data/dev_small/queries/all.zst -m recall --workers 4"
echo ""
echo "======================================"
