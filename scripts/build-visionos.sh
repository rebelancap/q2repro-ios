#!/usr/bin/env bash
# One command: build (and optionally install) the visionOS-native q2repro on Apple
# Vision Pro. Same source tree, same generated project as iOS — only retargeted to
# the XROS SDK via Q2_VISIONOS=1. The iOS build is never touched by this script.
#
#   scripts/build-visionos.sh              # build .app for a connected Vision Pro
#   scripts/build-visionos.sh --install    # build, then install + launch on device
#
# Prereqs (all produced by earlier one-command scripts, checked below):
#   - ANGLE for visionOS   → spikes/angle-prebuilt-visionos/{libEGL,libGLESv2}.framework
#                            (rebuild: scripts/build-angle-visionos.sh)
#   - FFmpeg + libcurl xros → work/xros-deps/prefix/lib/*.a
#                            (rebuild: scripts/build-ffmpeg-visionos.sh + build-curl-visionos.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build-visionos"

# --- prereqs (fail loud, with the exact fix command) ------------------------
[ -d "$ROOT/spikes/angle-prebuilt-visionos/libEGL.framework" ] || {
  echo "FATAL: ANGLE-for-visionOS missing. Run: scripts/build-angle-visionos.sh" >&2; exit 1; }
ls "$ROOT"/work/xros-deps/prefix/lib/libavcodec.a >/dev/null 2>&1 || {
  echo "FATAL: FFmpeg xros libs missing. Run: scripts/build-ffmpeg-visionos.sh" >&2; exit 1; }
ls "$ROOT"/work/xros-deps/prefix/lib/libcurl.a >/dev/null 2>&1 || {
  echo "FATAL: libcurl xros lib missing. Run: scripts/build-curl-visionos.sh" >&2; exit 1; }

# The generated project.yml / .xcodeproj are shared with the iOS build. Retarget them
# for visionOS to build, then always restore the default iOS project on exit so a normal
# iOS build is never left broken (this script is a variant, not a mode switch).
restore_ios_project() {
  Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh" >/dev/null 2>&1 || true
  ( cd "$ROOT/app" && xcodegen generate >/dev/null 2>&1 ) || true
  echo "== restored default iOS project =="
}
trap restore_ios_project EXIT

echo "== generating visionOS-retargeted project =="
Q2_ANGLE=1 Q2_VISIONOS=1 "$ROOT/scripts/gen-app-project.sh"
( cd "$ROOT/app" && xcodegen generate )

echo "== building for visionOS (generic device) =="
xcodebuild -project "$ROOT/app/q2repro.xcodeproj" -scheme q2repro -configuration Release \
  -derivedDataPath "$DERIVED" DEVELOPMENT_TEAM=57G8J46Z2T \
  -destination 'generic/platform=visionOS' build

APP="$(find "$DERIVED/Build/Products" -name 'q2repro.app' -maxdepth 3 | head -1)"
echo "built: $APP"

if [ "${1:-}" = "--install" ]; then
  # Pick the PHYSICAL, connected Vision Pro's coredevice UUID (skip simulators, which
  # show as "shutdown"/not "physical"). Grab the 8-4-4-4-12 UUID from that line only.
  DEV="$(xcrun devicectl list devices 2>/dev/null \
        | grep -i vision | grep -iw physical | grep -iw connected \
        | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)"
  [ -n "$DEV" ] || { echo "FATAL: no physical connected Vision Pro found via devicectl" >&2; exit 1; }
  echo "== target device: $DEV =="
  echo "== installing to $DEV =="
  xcrun devicectl device install app --device "$DEV" "$APP"
  echo "== launching =="
  xcrun devicectl device process launch --device "$DEV" com.rebelancap.q2repro
fi
