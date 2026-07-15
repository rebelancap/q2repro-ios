#!/usr/bin/env bash
# Build ANGLE (ES on Metal) for visionOS arm64 device — the graphics substrate for
# the visionOS-native q2repro. ANGLE's Metal backend is already visionOS-aware in
# source (TARGET_OS_VISION); the only gap upstream is that its gn build system has no
# xros platform. overlay/angle-visionos/build.patch adds one (SDK name, target triple,
# clang_rt, bundle kind, rust triple — 9 files, ~130 lines). Produces
# libEGL.framework + libGLESv2.framework as XROS slices (minos 26.0).
#
# One command: scripts/build-angle-visionos.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANGLE="$ROOT/spikes/angle"
OUT="$ANGLE/out/visionos-arm64-device"
PATCH="$ROOT/overlay/angle-visionos/build.patch"
export PATH="$ROOT/spikes/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0

# Bootstrap the ANGLE checkout if absent (gitignored / pruned to save ~12 GB).
if [ ! -f "$ANGLE/BUILD.gn" ]; then
  echo "ANGLE source not present; fetching (~12 GB)..."
  [ -x "$ROOT/spikes/depot_tools/fetch" ] || \
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$ROOT/spikes/depot_tools"
  mkdir -p "$ANGLE" && ( cd "$ANGLE" && DEPOT_TOOLS_UPDATE=1 fetch --no-history angle )
fi

# Apply the visionOS gn enablement patch to build/ (idempotent: skip if already in).
if git -C "$ANGLE/build" apply --reverse --check "$PATCH" >/dev/null 2>&1; then
  echo "visionOS gn patch already applied"
else
  echo "applying visionOS gn patch"
  git -C "$ANGLE/build" apply "$PATCH"
fi

mkdir -p "$OUT"
cat > "$OUT/args.gn" <<'EOF'
target_os = "ios"
target_cpu = "arm64"
target_platform = "xros"
target_environment = "device"
ios_deployment_target = "26.0"
ios_enable_code_signing = false
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
echo "=== gn gen ==="; ( cd "$ANGLE" && gn gen "$OUT" )
echo "=== building libEGL + libGLESv2 for visionOS ==="; ( cd "$ANGLE" && autoninja -C "$OUT" libEGL libGLESv2 )

DST="$ROOT/spikes/angle-prebuilt-visionos"
mkdir -p "$DST"
rm -rf "$DST/libEGL.framework" "$DST/libGLESv2.framework"
cp -R "$OUT/libEGL.framework" "$OUT/libGLESv2.framework" "$DST/"
echo "=== visionOS ANGLE frameworks staged in $DST ==="
for L in libEGL libGLESv2; do echo -n "$L: "; vtool -show-build "$DST/$L.framework/$L" 2>/dev/null | grep -i platform | head -1; done
