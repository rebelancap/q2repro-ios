#!/usr/bin/env bash
# Pre-OTA simulator validation for the two visionOS variants (CLAUDE.md REMOTE
# OPERATIONS). The visionOS SIMULATOR cannot composite immersive-space content into
# `simctl io screenshot` (immersive apps screenshot as passthrough + their 2D window),
# so the proof here is the ENGINE LOG reaching a known-good state, plus the 2D window
# screenshot. The stereo *visual* is a device-only check (batched into QUESTIONS.md).
#
#   scripts/sim-validate-visionos.sh [2d|3d|both]     # default: both
#
# Sim: the ONE program-shared "Apple Vision Pro" (visionOS 27.0). The old per-repo
# "q2repro-vision" device (visionOS 26.5) no longer exists, which settles the runtime
# question SHELL-GAPS item 10 / QUESTIONS Q-VR4 raised: 27.0 is now the only option
# and it matches the program rule. There is exactly one of these — check `simctl list
# devices booted` before claiming it, and never create a second.
# Prereqs (one command each): build-angle-visionos.sh + stage to angle-prebuilt-visionos-sim
# (xrsimulator slice), build-ffmpeg-visionos.sh simulator, build-curl-visionos.sh simulator.
#
# Taps can't be injected on the visionOS sim, so we drive via env hooks:
#   2D:  SIMCTL_CHILD_Q2_CMD="demomap demo1.dm2"  forces the classic attract demo at boot
#        (exercises overlay 0017 old-protocol playback — the PROTOCOL_NOT_SUPPORTED fix).
#   3D:  SIMCTL_CHILD_Q2_XR_AUTOENTER=1  auto-opens the immersive space
#        (exercises overlay 0018 world-render guard — the Enter-3D assertion fix).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="9D4499E9-CCED-4AF1-9303-925E9515D346"
OUTDIR="$ROOT/artifacts/sim"
GITREV="$(git -C "$ROOT" rev-parse --short HEAD)"
WHICH="${1:-both}"

restore_ios_project() {
  Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh" >/dev/null 2>&1 || true
  ( cd "$ROOT/app" && xcodegen generate >/dev/null 2>&1 ) || true
  echo "== restored default iOS project =="
}
# The trap OWNS the exit status (PASSED / FAILED / INTERRUPTED) — see
# scripts/lib/suite-trap.sh. It also runs the cleanup hook below on EVERY path.
SUITE_NAME="sim-validate-visionos"
. "$ROOT/scripts/lib/suite-trap.sh"
suite_cleanup_hook() {
  restore_ios_project
  # Lane discipline, always — pass, fail, or signal. OWN_LANE guards the polite case:
  # a run that aborted because another session already had the headset booted must not
  # tear down the lane it was being polite to.
  if [ "${OWN_LANE:-0}" = 1 ]; then
    xcrun simctl terminate "$UDID" com.rebelancap.q2repro 2>/dev/null || true
    xcrun simctl terminate "$UDID" com.rebelancap.q2repro3d 2>/dev/null || true
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    echo "== released visionOS lane $UDID =="
  fi
}
mkdir -p "$OUTDIR"

build_install() {
  local variant="$1" genflag="$2" bundle="$3" derived="$ROOT/build-visionos${4}-sim"
  echo "== [$variant] generate + build for the visionOS SIMULATOR =="
  env Q2_ANGLE=1 $genflag Q2_SIM=1 "$ROOT/scripts/gen-app-project.sh"
  ( cd "$ROOT/app" && xcodegen generate )
  mkdir -p "$derived"
  xcodebuild -project "$ROOT/app/q2repro.xcodeproj" -scheme q2repro -configuration Release \
    -destination "platform=visionOS Simulator,id=$UDID" -derivedDataPath "$derived" build \
    > "$derived/build.log" 2>&1 || { echo "[$variant] BUILD FAILED:" >&2; grep -m5 -B1 'error:' "$derived/build.log" >&2; exit 1; }
  local app; app="$(find "$derived/Build/Products" -name 'q2repro.app' -path '*xrsimulator*' -maxdepth 3 | head -1)"
  [ -n "$app" ] || { echo "[$variant] FATAL: no q2repro.app" >&2; exit 1; }
  xcrun simctl terminate "$UDID" "$bundle" 2>/dev/null || true
  xcrun simctl install "$UDID" "$app"
  echo "$app"
}

# The 3D app runs vanilla baseq2 (classic engine). The 2D app is seeded with the vanilla
# paks + the rerelease intro videos + Q2Game.kpf (the layout the user reported failing on).
seed_vanilla() { # $1 = bundle, $2 = 1 to also add rerelease video/kpf
  local cont; cont="$(xcrun simctl get_app_container "$UDID" "$1" data)"
  mkdir -p "$cont/Documents/baseq2"
  cp -c "$ROOT"/work/vp-stage-baseq2/pak?.pak "$cont/Documents/baseq2/" 2>/dev/null || true
  if [ "${2:-0}" = 1 ] && [ ! -d "$cont/Documents/baseq2/video" ]; then
    cp -Rc "$ROOT/work/gamedata/rerelease/baseq2/video" "$cont/Documents/baseq2/video"
    cp -c "$ROOT/work/gamedata/rerelease/Q2Game.kpf" "$cont/Documents/"
  fi
  echo "$cont"
}

echo "== boot $UDID =="
# There is exactly ONE visionOS simulator in the program. If somebody else already has it,
# do not fight them for it — and do not claim the lane, so the cleanup hook leaves it alone.
if xcrun simctl list devices booted | grep -q "$UDID"; then
  echo "NOTE: $UDID is already booted — reusing it, and NOT shutting it down at the end."
else
  sim_wait_shutdown "$UDID" || die "$UDID never reached state=Shutdown"
  xcrun simctl bootstatus "$UDID" -b
  OWN_LANE=1
fi

if [ "$WHICH" = 2d ] || [ "$WHICH" = both ]; then
  build_install "2D" "Q2_VISIONOS=1" com.rebelancap.q2repro "" >/dev/null
  CONT="$(seed_vanilla com.rebelancap.q2repro 1)"
  echo "== [2D] launch forcing the classic attract demo (overlay 0017) =="
  xcrun simctl terminate "$UDID" com.rebelancap.q2repro 2>/dev/null || true
  SIMCTL_CHILD_Q2_CMD="demomap demo1.dm2" xcrun simctl launch "$UDID" com.rebelancap.q2repro
  LOG="$CONT/Documents/baseq2/logs/console.log"
  for i in $(seq 1 20); do sleep 3; grep -q 'Old-protocol demo\|Couldn.t init demo context' "$LOG" 2>/dev/null && break; done
  xcrun simctl io "$UDID" screenshot "$OUTDIR/vp2d-$GITREV.png" >/dev/null 2>&1 || true
  echo "-- [2D] verdict --"
  if grep -q "Couldn't init demo context" "$LOG" 2>/dev/null; then
    fail "PROTOCOL_NOT_SUPPORTED still kills the demo"; grep "demo context" "$LOG" | tail -1
  elif grep -q 'Old-protocol demo: playing without seek snapshots' "$LOG" 2>/dev/null; then
    pass "old-protocol demo plays without snapshots (overlay 0017)"; grep 'Old-protocol' "$LOG" | tail -1
  else
    # Not a pass. "We could not tell" used to exit 0 here, which is the whole reason the
    # trap exists — inconclusive() counts as a failure.
    inconclusive "neither demo marker in $LOG"; tail -6 "$LOG" 2>/dev/null
  fi
fi

if [ "$WHICH" = 3d ] || [ "$WHICH" = both ]; then
  build_install "3D" "Q2_VISIONOS_3D=1" com.rebelancap.q2repro3d "-3d" >/dev/null
  CONT3="$(seed_vanilla com.rebelancap.q2repro3d 0)"
  echo "== [3D] launch auto-entering the immersive space (overlay 0018) =="
  xcrun simctl terminate "$UDID" com.rebelancap.q2repro3d 2>/dev/null || true
  SIMCTL_CHILD_Q2_XR_AUTOENTER=1 xcrun simctl launch "$UDID" com.rebelancap.q2repro3d
  LOG3="$CONT3/Documents/baseq2/logs/console.log"
  for i in $(seq 1 20); do sleep 3; grep -q 'Outer Base\|FATAL' "$LOG3" 2>/dev/null && break; done
  sleep 8   # let it render past the boot window where the old assertion fired
  xcrun simctl io "$UDID" screenshot "$OUTDIR/vp3d-$GITREV.png" >/dev/null 2>&1 || true
  ALIVE=$(ps aux | grep -c '[q]2repro.app/q2repro')
  echo "-- [3D] verdict --"
  if grep -qi 'R_RenderFrame.*assert\|FATAL: R_RenderFrame' "$LOG3" 2>/dev/null; then
    fail "R_RenderFrame assertion still fires"; grep -i 'assert' "$LOG3" | tail -1
  elif grep -q 'Outer Base' "$LOG3" 2>/dev/null && [ "$ALIVE" != 0 ]; then
    pass "base1 loaded, immersive space rendering, no assertion (overlay 0018). alive=$ALIVE"
  else
    inconclusive "base1='$(grep -c 'Outer Base' "$LOG3" 2>/dev/null)' alive=$ALIVE — inspect $LOG3"; tail -8 "$LOG3" 2>/dev/null
  fi
  echo "NOTE: the visionOS sim can't screenshot immersive content — stereo visual is a device check (QUESTIONS.md)."
fi
echo ""
echo "See $OUTDIR/vp*.png for the 2D windows; immersive frames are proved by the engine-side"
echo "composite readback assertions, not by window grabs (the sim cannot capture them)."
# NOTE: no explicit exit — the EXIT trap owns the verdict (PASSED / FAILED / INTERRUPTED).
