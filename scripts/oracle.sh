#!/usr/bin/env bash
# Drive the macOS parity oracle reproducibly and capture console + artifacts.
#
# Runs under a pty (`script`) so q2repro's line-buffered console output is
# actually flushed to the log (plain stdout redirection loses it when the
# process exits/aborts — the fps line and errors would vanish otherwise).
#
# Usage:
#   scripts/oracle.sh [options] [-- extra +console +commands]
# Options:
#   --rerelease         use the rerelease data set + rerelease game (MD5, hi-res)
#   --vanilla           use original baseq2 + classic game (default)
#   --map NAME          map to load (default base1)
#   --geom WxH          window geometry (default 1280x720)
#   --novsync           gl_swapinterval 0 (true renderer throughput)
#   --timerefresh       run timerefresh after load (128-frame 360° spin)
#   --screenshot        take a screenshot after load
#   --label L           artifact label (default = mode+map)
#   --wait N            frames to wait after map load before actions (default 450)
#
# Writes: artifacts/oracle-<label>.log ; screenshots land in the game tree and are
# copied to artifacts/oracle-<label>.jpg. Prints any fps line found.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/oracle/build-macos/q2repro"

MODE=vanilla MAP=base1 GEOM=1280x720 NOVSYNC=0 DO_TR=0 DO_SS=0 LABEL="" WAIT=450
EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    --rerelease) MODE=rerelease;;
    --vanilla)   MODE=vanilla;;
    --map)       MAP="$2"; shift;;
    --geom)      GEOM="$2"; shift;;
    --novsync)   NOVSYNC=1;;
    --timerefresh) DO_TR=1;;
    --screenshot)  DO_SS=1;;
    --label)     LABEL="$2"; shift;;
    --wait)      WAIT="$2"; shift;;
    --) shift; while [ $# -gt 0 ]; do EXTRA+=("$1"); shift; done; break;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
  shift
done

if [ "$MODE" = rerelease ]; then
  GD="$ROOT/work/gamedata/rerelease"; RRARGS=(+set com_rerelease 1)
else
  GD="$ROOT/work/gamedata"; RRARGS=(+set sys_forcegamelib "$GD/baseq2/gamearm64.dylib")
fi
[ -n "$LABEL" ] || LABEL="$MODE-$MAP"
LOG="$ROOT/artifacts/oracle-$LABEL.log"
SHOTS="$GD/baseq2/screenshots"

# Ensure the built game dylibs are linked into the data tree (idempotent).
for d in gamearm64.dylib game_arm64.dylib; do
  ln -sf "$ROOT/oracle/build-macos/baseq2/$d" "$GD/baseq2/$d"
done

seq_args=(+map "$MAP" +wait "$WAIT")
[ "$DO_TR" = 1 ] && seq_args+=(+timerefresh +wait 20)
[ "$DO_SS" = 1 ] && { rm -f "$SHOTS"/*.jpg "$SHOTS"/*.png 2>/dev/null; seq_args+=(+screenshot +wait 20); }
seq_args+=(+quit)

vsync=(); [ "$NOVSYNC" = 1 ] && vsync=(+set gl_swapinterval 0)

cd "$GD"
: > "$LOG"
script -q "$LOG" "$BIN" +set basedir "$GD" "${RRARGS[@]}" \
  +set vid_fullscreen 0 +set vid_geometry "$GEOM" "${vsync[@]}" \
  ${EXTRA[@]+"${EXTRA[@]}"} "${seq_args[@]}" >/dev/null 2>&1
rc=$?

# Strip ANSI/CR for a clean log alongside the raw capture.
sed $'s/\x1b\\[[0-9;]*[a-zA-Z]//g; s/\r//g' "$LOG" > "$LOG.clean" && mv "$LOG.clean" "$LOG"
if [ "$DO_SS" = 1 ]; then
  shot="$(ls -t "$SHOTS"/*.jpg "$SHOTS"/*.png 2>/dev/null | head -1)"
  [ -n "$shot" ] && cp "$shot" "$ROOT/artifacts/oracle-$LABEL.${shot##*.}" && echo "[oracle] screenshot -> artifacts/oracle-$LABEL.${shot##*.}"
fi
echo "[oracle] rc=$rc  log=artifacts/oracle-$LABEL.log"
grep -iE 'Loaded game library|[0-9.]+ seconds \(|Failed|FATAL|ERROR:' "$LOG" | tail -6
