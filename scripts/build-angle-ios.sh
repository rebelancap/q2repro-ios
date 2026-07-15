#!/usr/bin/env bash
# Build ANGLE (ES 3.1 on Metal) for iOS arm64 device — the candidate graphics
# substrate that un-gates q2repro's MD5 GPU-skeletal path (needs SSBO / ES 3.1).
# Produces libEGL.dylib + libGLESv2.dylib for embedding+signing in the app.
#
# One command: scripts/build-angle-ios.sh [device|simulator]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANGLE="$ROOT/spikes/angle"
ENV="${1:-device}"                 # device | simulator
OUT="$ANGLE/out/ios-arm64-$ENV"
export PATH="$ROOT/spikes/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0

# Bootstrap the ANGLE checkout if absent (it's gitignored / pruned to save ~16 GB).
if [ ! -d "$ANGLE/.git" ]; then
  echo "ANGLE source not present; fetching (~16 GB)..."
  if [ ! -x "$ROOT/spikes/depot_tools/fetch" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$ROOT/spikes/depot_tools"
  fi
  mkdir -p "$ANGLE" && ( cd "$ROOT/spikes/angle" && DEPOT_TOOLS_UPDATE=1 fetch --no-history angle )
fi

cd "$ANGLE"
mkdir -p "$OUT"
cat > "$OUT/args.gn" <<EOF
target_os = "ios"
target_cpu = "arm64"
target_environment = "$ENV"
ios_deployment_target = "15.0"
is_debug = false
is_component_build = false
angle_enable_metal = true
angle_enable_gl = false
angle_enable_vulkan = false
angle_enable_d3d11 = false
angle_enable_null = false
angle_enable_swiftshader = false
angle_enable_essl = true
angle_enable_glsl = true
angle_assert_always_on = false
angle_build_tests = false
treat_warnings_as_errors = false
EOF
echo "=== gn args ($OUT/args.gn) ==="; cat "$OUT/args.gn"
gn gen "$OUT"
echo "=== building libEGL + libGLESv2 ==="
autoninja -C "$OUT" libEGL libGLESv2
echo "=== ANGLE iOS ($ENV) build complete ==="
find "$OUT" -maxdepth 1 -name 'libEGL*' -o -maxdepth 1 -name 'libGLESv2*' | sort
