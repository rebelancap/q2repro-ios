#!/usr/bin/env bash
# Run a deterministic timedemo on the macOS oracle, capture the console log and
# the fps summary. Part of the Phase 0.3 measurement harness.
#
# Usage: run-timedemo.sh [demo] [gamedir] [WxH] [label] [extra +cmds...]
#   demo     demo name (default demo1)
#   gamedir  fs_basedir (default work/gamedata — original baseq2 tree)
#   WxH      window geometry (default 1280x720)
#   label    artifact label (default oracle)
#
# Writes: artifacts/timedemo-<label>.log  (full console)
# Prints: the fps summary line(s).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/oracle/build-macos/q2repro"
DEMO="${1:-demo1}"
BASEDIR="${2:-$ROOT/work/gamedata}"
GEOM="${3:-1280x720}"
LABEL="${4:-oracle}"
shift $(( $# < 4 ? $# : 4 )) || true
EXTRA=("$@")
OUT="$ROOT/artifacts/timedemo-$LABEL.log"

: > "$OUT"
echo "[run-timedemo] bin=$BIN demo=$DEMO basedir=$BASEDIR geom=$GEOM label=$LABEL" | tee -a "$OUT"

"$BIN" \
  +set basedir "$BASEDIR" \
  +set vid_fullscreen 0 \
  +set vid_geometry "$GEOM" \
  +set cl_async 0 \
  +set timedemo 1 \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  +demo "$DEMO" \
  >> "$OUT" 2>&1 &
PID=$!

# Poll up to 90s for the fps summary, then terminate the (otherwise-idle) client.
for _ in $(seq 1 180); do
  grep -qiE '[0-9]+ frames' "$OUT" && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.5
done
sleep 0.5
kill "$PID" 2>/dev/null || true
wait "$PID" 2>/dev/null || true

echo "=== timedemo result ($LABEL) ==="
grep -iE '[0-9]+ frames|fps|seconds' "$OUT" | tail -5 || echo "(no fps line — see $OUT)"
