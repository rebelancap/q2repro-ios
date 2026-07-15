#!/usr/bin/env bash
# One-command, deterministic setup from a clean checkout of THIS repo to a buildable
# Xcode project. Idempotent (safe to re-run) and loud (any failed step aborts).
#
#   scripts/bootstrap.sh            # set up everything, then generate the Xcode project
#   scripts/bootstrap.sh --build    # also build for a connected device
#
# What it does, in order:
#   1. vendor/q2repro  — pinned upstream clone + the rerelease-game git SUBMODULE
#      (a bare `git checkout` omits the submodule; overlay 0001 patches it, so it MUST
#       be initialized first — this was the gap the upstream-bump drill surfaced).
#   2. overlay         — apply the reviewable patch series onto pristine vendor.
#   3. native deps     — FFmpeg 7.1 + libcurl 8.11 iOS static libs (built once into
#                        work/ios-deps; skipped if already present).
#   4. project         — gen-app-project.sh → xcodegen.
# Prereqs on the machine: Xcode + command-line tools, xcodegen, meson/ninja + nasm
# (for the FFmpeg build), git. ANGLE frameworks + app/third_party are vendored in-repo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UPSTREAM_URL="https://github.com/Paril/q2repro.git"
UPSTREAM_PIN="1523f1130f44253a518c8acd2b74e24fc0315477"
VENDOR="$ROOT/vendor/q2repro"

echo "== [1/4] vendor/q2repro @ ${UPSTREAM_PIN:0:12} + rerelease-game submodule =="
if [ ! -d "$VENDOR/.git" ]; then
  git clone "$UPSTREAM_URL" "$VENDOR"
fi
git -C "$VENDOR" fetch --quiet origin
# Only hard-reset when clean — never clobber an overlay-applied working tree silently.
if [ -z "$(git -C "$VENDOR" status --porcelain)" ]; then
  git -C "$VENDOR" checkout --quiet "$UPSTREAM_PIN"
fi
git -C "$VENDOR" submodule update --init --recursive subprojects/rerelease-game
[ -f "$VENDOR/subprojects/rerelease-game/rerelease/game.h" ] || {
  echo "FATAL: rerelease-game submodule missing after init" >&2; exit 1; }

# Action Quake (aq2-tng) — classic-API game module (fs_game=action). Pinned clone, no overlay.
AQ_URL="https://github.com/actionquake/aq2-tng"
AQ_PIN="282af791b7ef2469fc78dc88ec099003bac952ff"
AQ="$ROOT/vendor/aq2-tng"
echo "== [1b/4] vendor/aq2-tng @ ${AQ_PIN:0:12} =="
[ -d "$AQ/.git" ] || git clone "$AQ_URL" "$AQ"
git -C "$AQ" fetch --quiet origin
if [ -z "$(git -C "$AQ" status --porcelain)" ]; then
  git -C "$AQ" checkout --quiet "$AQ_PIN"
fi
[ -d "$AQ/source" ] || { echo "FATAL: aq2-tng/source missing after clone" >&2; exit 1; }

echo "== [2/4] apply overlay =="
"$ROOT/scripts/apply-overlay.sh"

echo "== [3/4] native iOS static deps (FFmpeg 7.1 + libcurl 8.11) =="
if ls "$ROOT"/work/ios-deps/prefix/lib/libavcodec.a >/dev/null 2>&1; then
  echo "  FFmpeg present — skipping"
else
  "$ROOT/scripts/build-ffmpeg-ios.sh"
fi
if ls "$ROOT"/work/ios-deps/prefix/lib/libcurl.a >/dev/null 2>&1; then
  echo "  libcurl present — skipping"
else
  "$ROOT/scripts/build-curl-ios.sh"
fi
[ -d "$ROOT/spikes/angle-prebuilt-ios/libEGL.framework" ] || {
  echo "FATAL: ANGLE frameworks missing at spikes/angle-prebuilt-ios/ (vendored)" >&2; exit 1; }

echo "== [4/4] generate Xcode project =="
Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh"
( cd "$ROOT/app" && xcodegen generate )

echo
echo "bootstrap OK. Open app/q2repro.xcodeproj, or:"
echo "  xcodebuild -project app/q2repro.xcodeproj -scheme q2repro -configuration Release \\"
echo "    -derivedDataPath build-angle DEVELOPMENT_TEAM=57G8J46Z2T -destination 'generic/platform=iOS' build"

if [ "${1:-}" = "--build" ]; then
  echo "== --build: building for device =="
  xcodebuild -project "$ROOT/app/q2repro.xcodeproj" -scheme q2repro -configuration Release \
    -derivedDataPath "$ROOT/build-angle" DEVELOPMENT_TEAM=57G8J46Z2T \
    -destination 'generic/platform=iOS' build
fi
