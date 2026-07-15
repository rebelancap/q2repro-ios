#!/usr/bin/env bash
# Upstream-bump drill (charter acceptance): move the pinned upstream forward and rebuild.
# One command. Loud: a patch that no longer applies aborts so it can be rebased deliberately.
#
#   scripts/bump-upstream.sh <commit-ish>     # e.g. origin/master, or a specific SHA
#
# Steps: fetch upstream → checkout the new commit → re-init the rerelease-game submodule →
# re-apply the overlay (patch series) → regenerate the Xcode project. Then review the diff,
# update UPSTREAM_PIN in bootstrap.sh + docs, and run a device build to confirm green.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/q2repro"
TARGET="${1:?usage: bump-upstream.sh <commit-ish>}"

echo "== fetch + checkout $TARGET =="
git -C "$VENDOR" fetch --quiet origin --tags
# The vendor tree carries the applied overlay as uncommitted changes; stash-free reset via
# checkout of tracked files to pristine, then move to the target commit.
git -C "$VENDOR" checkout --quiet -- . 2>/dev/null || true
git -C "$VENDOR" checkout --quiet "$TARGET"
NEW="$(git -C "$VENDOR" rev-parse HEAD)"
echo "  now at $NEW"

echo "== re-init rerelease-game submodule =="
git -C "$VENDOR" submodule update --init --recursive subprojects/rerelease-game

echo "== re-apply overlay =="
"$ROOT/scripts/apply-overlay.sh"

echo "== regenerate project =="
Q2_ANGLE="${Q2_ANGLE:-1}" "$ROOT/scripts/gen-app-project.sh"
( cd "$ROOT/app" && xcodegen generate )

echo
echo "bump applied cleanly to $NEW."
echo "Next: update UPSTREAM_PIN=$NEW in scripts/bootstrap.sh + docs/frame-flow.md,"
echo "then build for device to confirm green:"
echo "  xcodebuild -project app/q2repro.xcodeproj -scheme q2repro -configuration Release \\"
echo "    -derivedDataPath build-angle DEVELOPMENT_TEAM=57G8J46Z2T -destination 'generic/platform=iOS' build"
