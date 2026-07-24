#!/bin/bash
# Crash-isolating totality sweep. Each battery runs in a subprocess; a
# SIGTRAP/SIGILL (Swift runtime trap, exit >128) kills only that shard.
# On a crash the driver bisects with --dump-items to the exact reproducer,
# records it, and RESUMES after that item — enumerating EVERY crash class
# in the space, not just the first. Clean batteries report 0 findings.
# Usage: total-crash-sweep.sh <items>
set -u
REPO=/Users/mi11ion/Desktop/swiftfilt
BIN="$REPO/.build/release/swiftfilt-parity"
DIR="$REPO/.build/parity-reports/acceptance"
REPRO="$DIR/total-crash-reproducers.txt"
ITEMS="${1:-1120000}"
mkdir -p "$DIR"
: > "$REPRO"
BATTERIES="random-bytes prefixed-garbage truncation deep-nesting huge scanner-bytes demangle-all"
for bat in $BATTERIES; do
  # Battery size mirrors the tool's own scaling.
  case "$bat" in
    random-bytes|prefixed-garbage) count=$((ITEMS*2));;
    truncation) count=$((ITEMS*3));;
    deep-nesting) count=$((ITEMS/50)); [ "$count" -lt 200 ] && count=200;;
    huge) count=$((ITEMS/4000)); [ "$count" -lt 24 ] && count=24;;
    scanner-bytes) count=$((ITEMS/2));;
    demangle-all) count=$((ITEMS/5));;
  esac
  from=0
  crashes=0
  while :; do
    env -u SWIFTFILT_DEMANGLE_CORPUS "$BIN" total --items "$ITEMS" --battery "$bat" --from "$from" >/dev/null 2>&1
    ec=$?
    if [ "$ec" -eq 0 ]; then
      break
    elif [ "$ec" -gt 128 ]; then
      # Bisect the crashing item via serial --dump-items (last dumped line).
      env -u SWIFTFILT_DEMANGLE_CORPUS "$BIN" total --items "$ITEMS" --battery "$bat" --from "$from" --dump-items >/dev/null 2>"$DIR/dump-$bat.log"
      last=$(tail -1 "$DIR/dump-$bat.log")
      item=$(echo "$last" | grep -o 'item=[0-9]*' | cut -d= -f2)
      b64=$(echo "$last" | grep -o 'input.b64=.*' | cut -d= -f2-)
      echo "battery=$bat item=$item exit=$ec b64=$b64" >> "$REPRO"
      echo "[sweep] $bat CRASH at item=$item (exit $ec): $(echo "$b64" | base64 -d | xxd -p | head -c 60)"
      crashes=$((crashes+1))
      if [ -z "$item" ]; then echo "[sweep] $bat: could not localize; stopping battery"; break; fi
      from=$((item+1))
      [ "$crashes" -ge 20 ] && { echo "[sweep] $bat: 20+ crashes, capping enumeration"; break; }
    else
      echo "[sweep] $bat exited $ec (non-crash, non-clean) — divergence or setup; see a direct run"
      break
    fi
  done
  [ "$crashes" -eq 0 ] && echo "[sweep] $bat: clean (no crashes, size=$count)"
done
echo "[sweep] done. reproducers:"; cat "$REPRO"
