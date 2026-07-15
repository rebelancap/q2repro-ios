#!/usr/bin/env bash
# Pre-OTA simulator validation for the two visionOS variants (CLAUDE.md REMOTE
# OPERATIONS). The visionOS SIMULATOR cannot composite immersive-space content into
# `simctl io screenshot` (immersive apps screenshot as passthrough + their 2D window),
# so the proof here is the ENGINE LOG reaching a known-good state, plus the 2D window
# screenshot. The stereo *visual* is a device-only check (batched into QUESTIONS.md).
#
#   scripts/sim-validate-visionos.sh [2d|3d|both]     # default: both
#
# Sim: "q2repro-vision" (Apple Vision Pro, visionOS 26.5), UDID below — THIS repo's own.
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
UDID="30F5DAA4-0412-4C2E-B9B2-FEA70E1316AF"
OUTDIR="$ROOT/artifacts/sim"
GITREV="$(git -C "$ROOT" rev-parse --short HEAD)"
WHICH="${1:-both}"

restore_ios_project() {
  Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh" >/dev/null 2>&1 || true
  ( cd "$ROOT/app" && xcodegen generate >/dev/null 2>&1 ) || true
  echo "== restored default iOS project =="
}
trap restore_ios_project EXIT
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
xcrun simctl bootstatus "$UDID" -b

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
    echo "FAIL: PROTOCOL_NOT_SUPPORTED still kills the demo"; grep "demo context" "$LOG" | tail -1; exit 1
  elif grep -q 'Old-protocol demo: playing without seek snapshots' "$LOG" 2>/dev/null; then
    echo "PASS: old-protocol demo plays without snapshots (overlay 0017)"; grep 'Old-protocol' "$LOG" | tail -1
  else
    echo "INCONCLUSIVE: neither marker in $LOG — inspect it"; tail -6 "$LOG" 2>/dev/null
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
    echo "FAIL: R_RenderFrame assertion still fires"; grep -i 'assert' "$LOG3" | tail -1; exit 1
  elif grep -q 'Outer Base' "$LOG3" 2>/dev/null && [ "$ALIVE" != 0 ]; then
    echo "PASS: base1 loaded, immersive space rendering, no assertion (overlay 0018). alive=$ALIVE"
  else
    echo "INCONCLUSIVE: base1='$(grep -c 'Outer Base' "$LOG3" 2>/dev/null)' alive=$ALIVE — inspect $LOG3"; tail -8 "$LOG3" 2>/dev/null
  fi
  echo "NOTE: the visionOS sim can't screenshot immersive content — stereo visual is a device check (QUESTIONS.md)."
fi
echo ""
echo "DONE — logs are the proof here (sim can't capture immersive frames). See $OUTDIR/vp*.png for the 2D windows."
