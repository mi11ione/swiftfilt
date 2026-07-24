#!/bin/bash
# Checkpointed full-corpus live acceptance: 1M-row foreground chunks.
# Usage: run-live-chunks.sh <first-chunk> <last-chunk>
# Each chunk: swiftfilt-parity live --skip N*1M --limit 1M --tag cNN
# Appends per-chunk logs + a checkpoint line; skips chunks already done.
set -u
REPO=/Users/mi11ion/Desktop/swiftfilt
DIR="$REPO/.build/parity-reports/acceptance"
CK="$DIR/checkpoint.log"
CORPUS="${SWIFTFILT_DEMANGLE_CORPUS:?set SWIFTFILT_DEMANGLE_CORPUS to the manifest.tsv path}"
CHUNK=1000000
mkdir -p "$DIR"
for i in $(seq "$1" "$2"); do
  tag=$(printf 'c%02d' "$i")
  if grep -q "^done chunk=$tag " "$CK" 2>/dev/null; then
    echo "[driver] $tag already complete — skipping"
    continue
  fi
  skip=$((i * CHUNK))
  echo "[driver] $tag starting (skip=$skip limit=$CHUNK) $(date +%H:%M:%S)"
  SWIFTFILT_DEMANGLE_CORPUS="$CORPUS" "$REPO/.build/release/swiftfilt-parity" \
    live --skip "$skip" --limit "$CHUNK" --tag "$tag" > "$DIR/live-$tag.log" 2>&1
  ec=$?
  processed=$(grep -o 'symbols processed: [0-9,]*' "$DIR/live-$tag.log" | head -1 | tr -d ',' | awk '{print $3}')
  gating=$(grep -o 'UNEXPLAINED DIVERGENCES: [0-9,]*' "$DIR/live-$tag.log" | head -1 | tr -d ',' | awk '{print $3}')
  echo "done chunk=$tag exit=$ec processed=${processed:-0} gating=${gating:-?} at=$(date +%H:%M:%S)" >> "$CK"
  echo "[driver] $tag done: exit=$ec processed=${processed:-0} gating=${gating:-?}"
  if [ -z "$processed" ] || [ "$processed" = "0" ]; then
    echo "[driver] $tag processed nothing — corpus exhausted"
    break
  fi
done
echo "[driver] batch complete $(date +%H:%M:%S)"
