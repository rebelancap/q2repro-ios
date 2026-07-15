#!/usr/bin/env bash
# Mandatory pre-OTA simulator validation (CLAUDE.md REMOTE OPERATIONS): build the iOS
# app for the SIMULATOR, install + launch it on this repo's dedicated sim, seed the
# rerelease game data, and capture timed content screenshots into artifacts/sim/.
# Ships only what the sim already proved — screenshots, never logs alone.
#
#   scripts/sim-validate.sh
#
# Sim: "q2repro-air" (iPhone Air, iOS 27.0), UDID below — created for THIS repo.
# Never boot the HarbourMasters sessions' sims (36079716-…, 5B40BEAC-…).
#
# Prereqs (each one command): scripts/build-angle-ios.sh simulator (staged to
# spikes/angle-prebuilt-ios-sim), scripts/build-ffmpeg-ios.sh simulator,
# scripts/build-curl-ios.sh simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="713AEF82-796C-4E9C-8A97-70722ECCA2E6"
BUNDLE=com.rebelancap.q2repro
DERIVED="$ROOT/build-ios-sim"
OUTDIR="$ROOT/artifacts/sim"
GITREV="$(git -C "$ROOT" rev-parse --short HEAD)"

# Shared generated project: always restore the device default on exit.
restore_ios_project() {
  Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh" >/dev/null 2>&1 || true
  ( cd "$ROOT/app" && xcodegen generate >/dev/null 2>&1 ) || true
  echo "== restored default iOS project =="
}
trap restore_ios_project EXIT

echo "== generate simulator-retargeted project =="
Q2_ANGLE=1 Q2_SIM=1 "$ROOT/scripts/gen-app-project.sh"
( cd "$ROOT/app" && xcodegen generate )

echo "== build for iOS Simulator =="
LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
xcodebuild -project "$ROOT/app/q2repro.xcodeproj" -scheme q2repro -configuration Release \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" build \
  > "$LOG" 2>&1 || { echo "SIM BUILD FAILED — tail of $LOG:" >&2; tail -40 "$LOG" >&2; exit 1; }
APP="$(find "$DERIVED/Build/Products" -name 'q2repro.app' -path '*iphonesimulator*' -maxdepth 3 | head -1)"
[ -n "$APP" ] || { echo "FATAL: no simulator q2repro.app produced" >&2; exit 1; }
echo "built: $APP"

echo "== boot sim + install =="
xcrun simctl bootstatus "$UDID" -b
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "== seed rerelease game data (Steam layout, idempotent) =="
# work/gamedata/rerelease is the COMPLETE set (pak + kpf + video/ + music) — the
# minimal ios-stage-rr set boots but the intro cinematic needs baseq2/video/.
CONT="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)"
if [ ! -f "$CONT/Documents/rerelease/baseq2/video/ntro.ogv" ]; then
  rm -rf "$CONT/Documents/rerelease"
  cp -Rc "$ROOT/work/gamedata/rerelease" "$CONT/Documents/rerelease" 2>/dev/null \
    || cp -R "$ROOT/work/gamedata/rerelease" "$CONT/Documents/rerelease"
fi

echo "== launch + capture =="
mkdir -p "$OUTDIR"
# Launch twice: the first launch after a fresh sim boot can win the race against
# SpringBoard and run without ever being foregrounded (home screen stays visible).
xcrun simctl launch "$UDID" "$BUNDLE"
sleep 4
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE"
# Timeline with the rerelease set: intro cinematic ≈0–150s, attract demo after.
last=0
for t in 10 75 180 230; do
  sleep "$((t - last))"; last=$t
  shot="$OUTDIR/sim-$GITREV-${t}s.png"
  xcrun simctl io "$UDID" screenshot "$shot" >/dev/null
  echo "captured $shot ($(stat -f %z "$shot") bytes)"
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
echo ""
echo "DONE — review the screenshots in $OUTDIR (content, not logs, is the proof)."
