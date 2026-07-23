#!/usr/bin/env bash
# Package fainder-redone + Claude project state for local download.
# Excludes big regeneratable artifacts (target/, data/, ablation logs, venv, PDFs).
#
# Usage:
#   bash scripts/tar_project_for_local.sh        # slim: no .git (~50 MB)
#   bash scripts/tar_project_for_local.sh full   # includes .git (~370 MB)

set -euo pipefail

REPO=/home/abumukh-ldap/fainder-redone
CLAUDE=/home/abumukh-ldap/.claude/projects/-home-abumukh-ldap-fainder-redone
DATE=$(date +%Y%m%d)
MODE="${1:-slim}"

if [[ "$MODE" == "full" ]]; then
    OUT="$REPO/fainder-project-full-${DATE}.tar.gz"
    GIT_EXCLUDE=""
else
    OUT="$REPO/fainder-project-slim-${DATE}.tar.gz"
    GIT_EXCLUDE="--exclude=fainder-redone/.git"
fi
# Write tar to /tmp first, then move — avoids "file changed as we read it" from
# the output tarball being inside the tree tar is walking.
TMP_OUT="/tmp/$(basename "$OUT")"

# Remove older bundles of the same mode so only newest remains
rm -f "$REPO"/fainder-project-${MODE}-*.tar.gz "$TMP_OUT"

# Stage the Claude state under fainder-redone/.claude-state/ so it rides in the same tarball
STAGE_DIR="$REPO/.claude-state"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
# Only copy the state files we care about; skip the giant transcript unless in full mode
cp -r "$CLAUDE/memory" "$STAGE_DIR/"
[[ -d "$CLAUDE/memory_archive_2026-04-29" ]] && cp -r "$CLAUDE/memory_archive_2026-04-29" "$STAGE_DIR/"
# Chat history — the .jsonl is 30 MB, include only in full mode
if [[ "$MODE" == "full" ]]; then
    cp "$CLAUDE"/*.jsonl "$STAGE_DIR/" 2>/dev/null || true
fi

# Build the tarball from /home/abumukh-ldap so paths inside look like fainder-redone/...
cd /home/abumukh-ldap
tar czf "$TMP_OUT" \
    --exclude='fainder-redone/target' \
    --exclude='fainder-redone/data' \
    --exclude='fainder-redone/venv' \
    --exclude='fainder-redone/logs/ablation' \
    --exclude='fainder-redone/logs/query_execution_*.log' \
    --exclude='fainder-redone/*.tar.gz' \
    --exclude='fainder-redone/Fainder.pdf' \
    --exclude='fainder-redone/Thesis Proposal Draft*.pdf' \
    --exclude='fainder-redone/**/__pycache__' \
    --exclude='fainder-redone/**/.pytest_cache' \
    --exclude='fainder-redone/**/*.pyc' \
    $GIT_EXCLUDE \
    fainder-redone
mv "$TMP_OUT" "$OUT"

# Clean up the staged Claude state (it's now inside the tar)
rm -rf "$STAGE_DIR"

echo
echo "=== Result ==="
ls -lh "$OUT"
echo
echo "=== Top-level contents ==="
tar tzf "$OUT" | awk -F/ '{print $2}' | sort -u | head -30
echo
echo "=== Total files: $(tar tzf "$OUT" | wc -l) ==="
