#!/usr/bin/env bash
# Re-pack the walkthrough for Lennart. Runs from anywhere.
set -euo pipefail

REPO=/home/abumukh-ldap/fainder-redone
TMPDIR=/tmp/lennart_bundle
DATE=$(date +%Y%m%d)
OUT="$REPO/fainder-walkthrough-lennart-${DATE}.tar.gz"

rm -rf "$TMPDIR"
mkdir -p "$TMPDIR/walkthrough" "$TMPDIR/logs"

cp "$REPO"/analysis/walkthrough/*.ipynb "$TMPDIR/walkthrough/"
# README optional — only copy if it exists
[[ -f "$REPO/analysis/walkthrough/README.md" ]] && cp "$REPO/analysis/walkthrough/README.md" "$TMPDIR/walkthrough/"
cp "$REPO/logs/bench.db" "$TMPDIR/logs/"

# Remove any older bundles from today or earlier so only the newest remains
rm -f "$REPO"/fainder-walkthrough-lennart-*.tar.gz
tar czf "$OUT" -C "$TMPDIR" walkthrough logs

echo "$OUT"
ls -lh "$OUT"
