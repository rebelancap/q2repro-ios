#!/usr/bin/env bash
# One command: build (and optionally install) the visionOS-3D (immersive) q2repro on Apple
# Vision Pro. Same source tree as the iOS / 2D-visionOS builds — retargeted via Q2_VISIONOS_3D=1,
# which swaps the UIKit shell (main.m) + 2D ANGLE window driver (vid_angle.m) for the SwiftUI +
# Compositor Services immersive shell in app/Sources/immersive/. The engine renders (via ANGLE)
# straight into the per-eye drawable textures. Neither the iOS nor the 2D-visionOS build is touched.
#
#   scripts/build-visionos-3d.sh              # build .app for a connected Vision Pro
#   scripts/build-visionos-3d.sh --install    # build, then install + launch on device
#
# Prereqs are identical to the 2D visionOS build (ANGLE-for-xros, FFmpeg + libcurl xros).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build-visionos-3d"

# --- prereqs (fail loud, with the exact fix command) ------------------------
[ -d "$ROOT/spikes/angle-prebuilt-visionos/libEGL.framework" ] || {
  echo "FATAL: ANGLE-for-visionOS missing. Run: scripts/build-angle-visionos.sh" >&2; exit 1; }
ls "$ROOT"/work/xros-deps/prefix/lib/libavcodec.a >/dev/null 2>&1 || {
  echo "FATAL: FFmpeg xros libs missing. Run: scripts/build-ffmpeg-visionos.sh" >&2; exit 1; }
ls "$ROOT"/work/xros-deps/prefix/lib/libcurl.a >/dev/null 2>&1 || {
  echo "FATAL: libcurl xros lib missing. Run: scripts/build-curl-visionos.sh" >&2; exit 1; }

# The generated project.yml / .xcodeproj are shared with the iOS build. Retarget for the 3D
# variant to build, then always restore the default iOS project on exit (this is a variant,
# not a persistent mode switch).
restore_ios_project() {
  Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh" >/dev/null 2>&1 || true
  ( cd "$ROOT/app" && xcodegen generate >/dev/null 2>&1 ) || true
  echo "== restored default iOS project =="
}
# The trap OWNS the exit status (PASSED / FAILED / INTERRUPTED) — see
# scripts/lib/suite-trap.sh. It also runs the cleanup hook below on EVERY path.
SUITE_NAME="build-visionos-3d"
. "$ROOT/scripts/lib/suite-trap.sh"
suite_cleanup_hook() { restore_ios_project; }

echo "== generating visionOS-3D (immersive) project =="
Q2_ANGLE=1 Q2_VISIONOS_3D=1 "$ROOT/scripts/gen-app-project.sh"
( cd "$ROOT/app" && xcodegen generate )

echo "== building for visionOS-3D (generic device) =="
xcodebuild -project "$ROOT/app/q2repro.xcodeproj" -scheme q2repro -configuration Release \
  -derivedDataPath "$DERIVED" DEVELOPMENT_TEAM=57G8J46Z2T \
  -destination 'generic/platform=visionOS' build

APP="$(find "$DERIVED/Build/Products" -name 'q2repro.app' -maxdepth 3 | head -1)"
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  DEV="$(xcrun devicectl list devices 2>/dev/null \
        | grep -i vision | grep -iw physical | grep -iw connected \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)"
  [ -n "$DEV" ] || { echo "FATAL: no physical connected Vision Pro found via devicectl" >&2; exit 1; }
  echo "== target device: $DEV =="
  echo "== installing to $DEV =="
  xcrun devicectl device install app --device "$DEV" "$APP"
  echo "== launching =="
  xcrun devicectl device process launch --device "$DEV" com.rebelancap.q2repro3d
fi
