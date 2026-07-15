#!/usr/bin/env bash
# Build (and optionally install) the standalone visionOS immersive spike.
#   spikes/visionos-immersive/build.sh            # build only
#   spikes/visionos-immersive/build.sh --install  # build + install + launch on Vision Pro
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
DEV="8EF595AD-9C0A-51FE-A0AF-E3A6AB787626"
cd "$ROOT"
xcodegen generate
xcodebuild -project ImmersiveSpike.xcodeproj -scheme ImmersiveSpike -configuration Debug \
  -derivedDataPath build DEVELOPMENT_TEAM=57G8J46Z2T \
  -destination 'generic/platform=visionOS' build
APP="$(find build/Build/Products -name 'ImmersiveSpike.app' | head -1)"
echo "built: $APP"
if [ "${1:-}" = "--install" ]; then
  xcrun devicectl device install app --device "$DEV" "$APP"
  xcrun devicectl device process launch --device "$DEV" com.q2repro.immersivespike
fi
