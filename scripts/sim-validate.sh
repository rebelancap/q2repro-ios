#!/usr/bin/env bash
# Mandatory pre-OTA simulator validation (CLAUDE.md REMOTE OPERATIONS): build the iOS
# app for the SIMULATOR, install + launch it on this repo's dedicated sim, seed the
# rerelease game data, and capture timed content screenshots into artifacts/sim/.
# Ships only what the sim already proved — screenshots, never logs alone.
#
#   scripts/sim-validate.sh
#
# Sim: the PROGRAM-SHARED "iPhone Air" (iOS 27.0), lane 2 of ~/dev/CLAUDE.md's lane
# table. The old per-repo "q2repro-air" device is gone (per-project simulators were
# purged program-wide: each carries its own data/ dir and they reached 179 GB).
# Never create a device; never boot another session's lane.
#
# Prereqs (each one command): scripts/build-angle-ios.sh simulator (staged to
# spikes/angle-prebuilt-ios-sim), scripts/build-ffmpeg-ios.sh simulator,
# scripts/build-curl-ios.sh simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UDID="45A5059C-8751-4FC5-9BB2-A3EF6FFCCC22"
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
# The trap OWNS the exit status (PASSED / FAILED / INTERRUPTED) — see
# scripts/lib/suite-trap.sh. It also runs the cleanup hook below on EVERY path.
SUITE_NAME="sim-validate-ios"
. "$ROOT/scripts/lib/suite-trap.sh"
suite_cleanup_hook() {
  restore_ios_project
  # Lane discipline, always — pass, fail, or signal. OWN_LANE guards the polite case:
  # a run that reused a device another session had booted must not shut it down.
  if [ "${OWN_LANE:-0}" = 1 ]; then
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
    xcrun simctl shutdown "$UDID" 2>/dev/null || true
    echo "== released iOS lane $UDID =="
  fi
}

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
if xcrun simctl list devices booted | grep -q "$UDID"; then
  echo "NOTE: $UDID already booted — reusing it, and NOT shutting it down at the end."
else
  sim_wait_shutdown "$UDID" || die "$UDID never reached state=Shutdown"
  xcrun simctl bootstatus "$UDID" -b
  OWN_LANE=1
fi
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

# CONTENT IS THE PROOF, and now it is ASSERTED rather than left for a human to squint at.
# This script used to exit 0 whatever the screenshots contained — a green run for a build
# that rendered nothing. Each capture must carry real pixels; the threshold is a small
# fraction of the frame so it survives a different moment in the timeline, and it measures
# a PREDICATE over the stored (sRGB) pixel rather than an intended colour.
echo "-- verdict: assert the captures carry content --"
for shot in "$OUTDIR"/sim-"$GITREV"-*.png; do
  [ -f "$shot" ] || { fail "no screenshot captured"; break; }
  if "$ROOT/scripts/sim-pixel-count.py" "$shot" --pred nonblack --min 20000 >/dev/null; then
    pass "content in $(basename "$shot")"
  else
    fail "$(basename "$shot") is (near) black — the app rendered nothing"
  fi
done
echo ""
echo "Screenshots: $OUTDIR. No explicit exit — the EXIT trap owns the verdict."
