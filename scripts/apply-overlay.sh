#!/usr/bin/env bash
# Apply the overlay patch series onto the pristine vendor tree.
#
# The vendor/ tree is never hand-edited; every local change to upstream lives as
# a reviewable patch in overlay/patches/ and is applied here. Idempotent (safe to
# re-run) and loud (a patch that neither applies nor is already applied fails the
# build). One command:  scripts/apply-overlay.sh
#
# Already-applied detection is STAMP-based: each successfully applied patch writes
# vendor/q2repro/.overlay-applied/<name>.sha256 (hash of the patch file). A fresh
# vendor clone has no stamps → the full series applies. A per-patch reverse-check
# was the old mechanism, but it breaks when a later patch inserts lines inside an
# earlier patch's context (stacked same-file patches — e.g. 0013+0019 in keys.c):
# such patches only reverse-apply in reverse SERIES order, not independently.
# Editing an already-applied patch file (hash change) fails loudly rather than
# guessing — re-clone vendor to rebuild from pristine.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/q2repro"
PATCHES="$ROOT/overlay/patches"
STAMPS="$VENDOR/.overlay-applied"

shopt -s nullglob
patches=("$PATCHES"/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
  echo "[overlay] no patches in $PATCHES"
  exit 0
fi
mkdir -p "$STAMPS"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

for p in "${patches[@]}"; do
  name="$(basename "$p")"
  stamp="$STAMPS/$name.sha256"
  want="$(sha "$p")"
  if [ -f "$stamp" ]; then
    if [ "$(cat "$stamp")" = "$want" ]; then
      echo "[overlay] already applied: $name"
      continue
    fi
    echo "[overlay] ERROR: $name changed since it was applied (stamp mismatch)." >&2
    echo "[overlay]        Re-clone vendor (scripts/bootstrap.sh) or revert the patch edit." >&2
    exit 1
  fi
  if patch -p1 -d "$VENDOR" --dry-run -f < "$p" >/dev/null 2>&1; then
    patch -p1 -d "$VENDOR" -f < "$p"
    echo "$want" > "$stamp"
    echo "[overlay] applied:        $name"
  elif patch -p1 -d "$VENDOR" --dry-run --reverse -f < "$p" >/dev/null 2>&1; then
    # Applied before the stamp mechanism existed (legacy) — adopt a stamp.
    echo "$want" > "$stamp"
    echo "[overlay] already applied (adopted stamp): $name"
  else
    echo "[overlay] ERROR: $name neither applies cleanly nor is already applied" >&2
    exit 1
  fi
done
echo "[overlay] series OK (${#patches[@]} patch(es))"
