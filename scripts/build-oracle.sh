#!/usr/bin/env bash
# Build the macOS parity oracle: q2repro built natively with the full feature
# set (FFmpeg cinematics+music, png/jpeg, OpenAL, MD5 models). This is the
# ground-truth reference for every later iOS visual/feel/perf comparison.
#
# One documented command:  scripts/build-oracle.sh [clean]
#
# Failures are loud: -e, no || true on compile steps.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor/q2repro"
BUILD="$ROOT/oracle/build-macos"

# Keg-only + standard brew formulae provide pkg-config metadata here.
PCP=""
for f in jpeg-turbo openal-soft ffmpeg sdl2 curl libpng; do
  p="$(brew --prefix "$f" 2>/dev/null)/lib/pkgconfig"
  [ -d "$p" ] && PCP="$PCP:$p"
done
export PKG_CONFIG_PATH="${PCP#:}${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

# Apply the overlay patch series onto the pristine vendor tree first (loud on
# failure). Required for macOS: overlay 0001 exports the rerelease game entry
# points on Apple platforms.
"$ROOT/scripts/apply-overlay.sh"

if [ "${1:-}" = "clean" ]; then
  rm -rf "$BUILD"
fi

if [ ! -d "$BUILD" ]; then
  # Portable build (system-wide=false): the binary expects to be launched from
  # the root of a Quake 2 data tree, or with fs_basedir pointed at one.
  # release buildtype for representative desktop performance.
  meson setup "$BUILD" "$VENDOR" \
    --buildtype=release \
    -Dsystem-wide=false \
    -Dsdl2=enabled \
    -Dopenal=enabled \
    -Dlibpng=enabled \
    -Dlibjpeg=enabled \
    -Davcodec=enabled \
    -Dlibcurl=enabled \
    -Dmd5=true \
    -Dmd3=true
fi

meson compile -C "$BUILD" -v
echo "=== ORACLE BUILD COMPLETE ==="
ls -la "$BUILD"/q2repro "$BUILD"/baseq2/game*.dylib 2>/dev/null || true
