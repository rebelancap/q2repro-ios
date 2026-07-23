#!/usr/bin/env bash
# Generate app/project.yml for the iOS q2repro app (D6: Xcode-native build).
# Engine sources come from scripts/gen-ios-sources.py (derived from meson), so an
# upstream bump + re-run keeps the target in sync. One command: scripts/gen-app-project.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/app/project.yml"

# The visionOS-3D (immersive) variant is a visionOS build with a different app shell
# (SwiftUI + Compositor Services instead of the UIKit SceneDelegate), so it implies Q2_VISIONOS.
if [ "${Q2_VISIONOS_3D:-0}" = "1" ]; then Q2_VISIONOS=1; fi

{
cat <<'HEAD'
name: q2repro
options:
  bundleIdPrefix: com.rebelancap
  deploymentTarget:
    iOS: "15.0"
  createIntermediateGroups: true
settings:
  base:
    PRODUCT_BUNDLE_IDENTIFIER: com.rebelancap.q2repro
    DEVELOPMENT_TEAM: 57G8J46Z2T
    CODE_SIGN_STYLE: Automatic
    TARGETED_DEVICE_FAMILY: "1"
    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon   # app icon (Assets.xcassets)
    STRIP_INSTALLED_PRODUCT: NO   # archives strip exported symbols → dlsym-class silent crashes
    MARKETING_VERSION: "1.0.8"
    CURRENT_PROJECT_VERSION: "1"
    GCC_C_LANGUAGE_STANDARD: gnu11
    GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS: NO
    CLANG_WARN_STRICT_PROTOTYPES: NO
    GCC_PREPROCESSOR_DEFINITIONS:
      - HAVE_CONFIG_H=1
      - USE_CLIENT=1
      - USE_REF=1
      - _GNU_SOURCE=1
      - Q2_USE_ANGLE=__ANGLE__
      # angle-bracket form avoids quote-escaping; resolves via -Iinc. Do NOT add
      # inc/common to the header path — it shadows the system <math.h>.
      - Q2PROTO_CONFIG_H=<common/q2proto_config.h>
    HEADER_SEARCH_PATHS:
      - $(SRCROOT)/Sources
      - $(SRCROOT)/khronos
      - $(SRCROOT)/third_party/egl
      - $(SRCROOT)/third_party/libpng
      - $(SRCROOT)/../work/ios-deps/prefix/include   # FFmpeg 7.1 (M7 cinematics + music)
      - $(SRCROOT)/../vendor/q2repro/inc
      - $(SRCROOT)/../vendor/q2repro/q2proto/inc
      - $(SRCROOT)/../vendor/q2repro
    OTHER_CFLAGS:
      - -fms-extensions
      - -fno-math-errno
      - -fno-trapping-math
      - -fsigned-char
      - -Wno-microsoft-anon-tag
      - -Wno-nontrivial-memcall
      - -Wno-implicit-function-declaration
    OTHER_LDFLAGS:
      - -lc++          # C++ runtime for the linked rerelease game static lib (M6)
      # FFmpeg 7.1 static (M7): linked individually — never merged (macOS `ar x`
      # drops duplicate object basenames; the linker handles them across archives).
      - -L$(SRCROOT)/../work/ios-deps/prefix/lib
      - -lavformat
      - -lavcodec
      - -lswscale
      - -lswresample
      - -lavutil
      - -lcurl          # MP server browser HTTP master queries (SecureTransport TLS)
targets:
  q2repro:
    type: application
    platform: iOS
    sources:
      - path: Sources
        excludes:
          - "immersive"     # visionOS-3D immersive shell; Q2_VISIONOS_3D swaps this for main.m + vid_angle.m
      - path: data          # bundled resources (q2repro.menu, installed to baseq2/ at boot)
HEAD

# meson-derived engine sources
python3 "$ROOT/scripts/gen-ios-sources.py" --yaml

cat <<'TAIL'
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: q2repro
        # xcodegen writes literal values into Info.plist; the $() forms keep the
        # build number driven by CURRENT_PROJECT_VERSION (publish-ota.sh stamps it)
        # and the VERSION by MARKETING_VERSION — without the latter, xcodegen bakes
        # a literal default "1.0" and SideStore updates silently never appear
        # (CFBundleShortVersionString must equal the release tag: guide §0).
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)
        CFBundleShortVersionString: $(MARKETING_VERSION)
        UILaunchScreen: {}
        CADisableMinimumFrameDurationOnPhone: true
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
        UIRequiredDeviceCapabilities: [arm64]
        UIStatusBarHidden: true
        UISupportedInterfaceOrientations:
          - UIInterfaceOrientationLandscapeRight
          - UIInterfaceOrientationLandscapeLeft
        CFBundleURLTypes:                       # q2repro:// deep links (Shortcuts/Siri/home screen)
          - CFBundleURLName: com.rebelancap.q2repro
            CFBundleURLSchemes: [q2repro]
    dependencies:
      - target: rrgame          # rerelease C++ game (M6); provides GetGameAPI @ current API
      - target: aqgame          # Action Quake (classic API); provides GetGameAPI_action
      - target: libpng          # PNG assets (rerelease hi-res / conchars.png)
      - sdk: OpenGLES.framework
      - sdk: QuartzCore.framework
      - sdk: UIKit.framework
      - sdk: libz.tbd
      - sdk: Metal.framework
      - sdk: AVFoundation.framework   # M7 audio: AVAudioSession
      - sdk: AudioToolbox.framework   # M7 audio: RemoteIO AudioUnit (snddma_coreaudio.m)
      - sdk: GameController.framework # Phase 2: MFi/Xbox/PS controller input
      - sdk: Security.framework       # libcurl SecureTransport TLS
      - sdk: SystemConfiguration.framework  # libcurl network config
      - framework: ../spikes/angle-prebuilt-ios/libEGL.framework
        embed: true
        codeSign: true
      - framework: ../spikes/angle-prebuilt-ios/libGLESv2.framework
        embed: true
        codeSign: true
  # ---- vanilla game module, static lib (D5). Own defines: NO USE_CLIENT/USE_REF.
  # Excludes shared.c/base85/m_flash (the app/engine target provides them → no dup symbols).
  game:
    type: library.static
    platform: iOS
    settings:
      base:
        GCC_C_LANGUAGE_STANDARD: gnu11
        GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS: NO
        CLANG_WARN_STRICT_PROTOTYPES: NO
        GCC_PREPROCESSOR_DEFINITIONS:
          - HAVE_CONFIG_H=1
          - _GNU_SOURCE=1
          # Symbol isolation for static linking: the game (g_main.c) has its own
          # gi-routed Com_Error/Com_LPrintf and a private `dedicated` cvar; rename
          # them so they don't collide with the engine's copies.
          - Com_Error=q2game_Com_Error
          - Com_LPrintf=q2game_Com_LPrintf
          - dedicated=q2game_dedicated
        HEADER_SEARCH_PATHS:
          - $(SRCROOT)/Sources
          - $(SRCROOT)/../vendor/q2repro/inc
          - $(SRCROOT)/../vendor/q2repro
        OTHER_CFLAGS:
          - -fms-extensions
          - -fno-math-errno
          - -fno-trapping-math
          - -fsigned-char
          - -Wno-microsoft-anon-tag
          - -Wno-implicit-function-declaration
    sources:
TAIL
python3 "$ROOT/scripts/gen-ios-sources.py" --game

cat <<'TAIL2'
  # ---- rerelease game module (C++), static lib (M6). KEX game API. fmt header-only.
  rrgame:
    type: library.static
    platform: iOS
    settings:
      base:
        CLANG_CXX_LANGUAGE_STANDARD: "c++17"
        CLANG_CXX_LIBRARY: "libc++"
        GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS: NO
        GCC_PREPROCESSOR_DEFINITIONS:
          - HAVE_CONFIG_H=1
          - NO_FMT_SOURCE=1
          - FMT_HEADER_ONLY=1
          - _GNU_SOURCE=1
          - Com_Error=q2game_Com_Error
          - Com_LPrintf=q2game_Com_LPrintf
          - dedicated=q2game_dedicated
        HEADER_SEARCH_PATHS:
          - $(SRCROOT)/rrgame
          - $(SRCROOT)/../vendor/q2repro/subprojects/rerelease-game/rerelease
          - $(SRCROOT)/../vendor/q2repro/inc
          - $(SRCROOT)/../vendor/q2repro
          - $(SRCROOT)/third_party/fmt/include
          - $(SRCROOT)/third_party/jsoncpp/include
        OTHER_CFLAGS:
          - -fms-extensions
          - -Wno-microsoft-anon-tag
          - -Wno-nontrivial-memcall
        OTHER_CPLUSPLUSFLAGS:
          - $(OTHER_CFLAGS)
          - -fms-extensions
          - -Wno-microsoft-anon-tag
          - -Wno-nontrivial-memcall
    sources:
TAIL2
python3 "$ROOT/scripts/gen-ios-sources.py" --rrgame

cat <<'TAIL_AQ'
  # ---- Action Quake (aq2-tng), classic Q2 game API v3, static lib. Uses ONLY its own
  # headers (source/*.h). Its GetGameAPI is renamed GetGameAPI_action; every shared.c
  # export is renamed aq_* (gen-ios-sources.py --aqdefs) so nothing collides with the
  # engine. Runs through the engine's GetGame3Proxy (old-API) path when fs_game=action.
  aqgame:
    type: library.static
    platform: iOS
    settings:
      base:
        GCC_C_LANGUAGE_STANDARD: gnu11
        GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS: NO
        CLANG_WARN_STRICT_PROTOTYPES: NO
        GCC_PREPROCESSOR_DEFINITIONS:
          - _GNU_SOURCE=1
          - GetGameAPI=GetGameAPI_action
TAIL_AQ
python3 "$ROOT/scripts/gen-ios-sources.py" --aqdefs

cat <<'TAIL_AQ2'
        HEADER_SEARCH_PATHS:
          - $(SRCROOT)/../vendor/aq2-tng/source
        OTHER_CFLAGS:
          - -fsigned-char
          # -fcommon: classic Q2 game code declares globals (gi, level, itemlist, …) in
          # headers without `extern`; modern clang's -fno-common makes each TU's tentative
          # definition a strong symbol → duplicate-symbol link warnings/merges. -fcommon
          # restores common-symbol merging so each global is a single shared instance.
          - -fcommon
          - -Wno-implicit-function-declaration
          - -Wno-implicit-int
          - -Wno-int-conversion
          - -Wno-format
          - -Wno-deprecated-non-prototype
    sources:
TAIL_AQ2
python3 "$ROOT/scripts/gen-ios-sources.py" --aqgame

cat <<'TAIL3'
  # ---- libpng (rerelease PNG assets). zlib from the iOS SDK. NEON opt off (arm/ not built).
  libpng:
    type: library.static
    platform: iOS
    settings:
      base:
        GCC_WARN_ABOUT_DEPRECATED_FUNCTIONS: NO
        GCC_PREPROCESSOR_DEFINITIONS:
          - PNG_ARM_NEON_OPT=0
    sources:
      - path: third_party/libpng
        excludes:
          - "pngtest.c"
TAIL3
} > "$OUT"
# Q2_ANGLE=1 selects the ANGLE-Metal video driver (else native EAGL). The ANGLE
# frameworks are always linked/embedded but inert when Q2_USE_ANGLE=0.
sed -i '' "s/Q2_USE_ANGLE=__ANGLE__/Q2_USE_ANGLE=${Q2_ANGLE:-1}/" "$OUT"
echo "wrote $OUT (Q2_USE_ANGLE=${Q2_ANGLE:-1})"

# (Q2_SIM is handled at the END of this script so it composes with the visionOS
# retargets below — it must rewrite the FINAL dep paths.)

# Q2_VISIONOS=1 retargets the SAME generated project to visionOS (the iOS build is
# unchanged when the flag is off). visionOS has no GLES (drop OpenGLES.framework),
# uses ANGLE built for xros, deps rebuilt against the XROS SDK, device family 7, and
# the UIScene life cycle (SceneDelegate lives in main.m behind #if TARGET_OS_VISION).
if [ "${Q2_VISIONOS:-0}" = "1" ]; then
  sed -i '' \
    -e 's/^    platform: iOS$/    platform: visionOS/' \
    -e 's/^    iOS: "15.0"$/    visionOS: "26.0"/' \
    -e 's/TARGETED_DEVICE_FAMILY: "1"/TARGETED_DEVICE_FAMILY: "7"/' \
    -e '/- sdk: OpenGLES.framework/d' \
    -e 's#angle-prebuilt-ios#angle-prebuilt-visionos#g' \
    -e 's#work/ios-deps/prefix#work/xros-deps/prefix#g' \
    "$OUT"
  # visionOS icon (1.0.1 hotfix): Files renders an app's folder icon only when the
  # catalog's layered stack is NAMED "AppIcon" (vkQuake parity — its working config is
  # Assets-visionos.xcassets/AppIcon.solidimagestack). The iOS AppIcon.appiconset has no
  # vision idiom (actool emits nothing for it on xros), so swap catalogs: exclude the iOS
  # one, add the visionOS one whose stack is AppIcon.
  sed -i '' -e 's/^          - "immersive"     .*/&\
          - "Assets.xcassets"   # visionOS icon comes from Assets-visionos.xcassets instead/' "$OUT"
  sed -i '' -e 's/^      - path: data          .*/      - path: Assets-visionos.xcassets\
        buildPhase: resources\
&/' "$OUT"
  # CFBundleIconName is how visionOS LaunchServices locates the app icon in the asset
  # catalog. xcodegen's generated Info.plist doesn't get the actool partial-plist merge
  # that would normally add it, so set it explicitly. Without this the icon renders blank.
  if [ "${Q2_VISIONOS_3D:-0}" = "1" ]; then
    # 3D shell is SwiftUI (@main App). It still needs a UIApplicationSceneManifest or
    # openImmersiveSpace() returns .error — but a SwiftUI-managed one: multiple-scene support
    # with an EMPTY UISceneConfigurations (no SceneDelegate). SwiftUI registers the WindowGroup
    # and ImmersiveSpace from the App body at runtime. (INFOPLIST_KEY_…Generation does NOT emit
    # this into an explicit Info.plist — only with GENERATE_INFOPLIST_FILE — so write it here.)
    MAN="$(mktemp)"; cat > "$MAN" <<'PLIST'
        CFBundleIconName: AppIcon
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
          UISceneConfigurations: {}
PLIST
  else
    # MERGED 2D+3D app: SwiftUI @main lifecycle (WindowGroup hosts the UIKit game;
    # ImmersiveSpace is the stereo panel). SwiftUI-managed scene manifest: multiple
    # scenes, EMPTY configurations, NO SceneDelegate (the class is compiled out under
    # Q2_XR_UI — also defeats UIKit's persisted-scene-session install-over trap).
    MAN="$(mktemp)"; cat > "$MAN" <<'PLIST'
        CFBundleIconName: AppIcon
        NSWorldSensingUsageDescription: q2repro places the 3D game screen in your room.
        UIApplicationSceneManifest:
          UIApplicationSupportsMultipleScenes: true
          UISceneConfigurations: {}
PLIST
  fi
  sed -i '' -e "/UILaunchScreen: {}/r $MAN" "$OUT"
  rm -f "$MAN"
  echo "retargeted $OUT for visionOS (SDKROOT xros, family 7)"
fi

# ---- MERGED visionOS 2D+3D (Q2_VISIONOS without Q2_VISIONOS_3D): compile the SwiftUI shell
# (VisionShell.swift) + the stereo mode in vid_angle.m/main.m (Q2_XR_UI=1). The standalone-3D
# shell files stay excluded; main.m keeps compiling (its main()/SceneDelegate drop out under
# Q2_XR_UI and the SwiftUI @main in VisionShell.swift is the entry).
if [ "${Q2_VISIONOS:-0}" = "1" ] && [ "${Q2_VISIONOS_3D:-0}" != "1" ]; then
  sed -i '' -e 's/          - "immersive"     .*/          - "immersive\/ImmersiveApp.swift"\
          - "immersive\/xr_boot.m"\
          - "immersive\/xr_render.m"/' "$OUT"
  sed -i '' -e 's/^      - Q2_USE_ANGLE=1$/      - Q2_USE_ANGLE=1\
      - Q2_XR_UI=1/' "$OUT"
  SET="$(mktemp)"; cat > "$SET" <<'YAML'
    SWIFT_VERSION: "5.0"
    SWIFT_OBJC_BRIDGING_HEADER: $(SRCROOT)/Sources/immersive/XR3Bridging.h
YAML
  sed -i '' -e "/^  base:$/r $SET" "$OUT"; rm -f "$SET"
  sed -i ''     -e 's/^      - sdk: Metal.framework$/      - sdk: Metal.framework\
      - sdk: CompositorServices.framework\
      - sdk: SwiftUI.framework\
      - sdk: ARKit.framework/'     "$OUT"
  echo "retargeted $OUT for the MERGED visionOS 2D+3D app (Q2_XR_UI)"
fi

# ---- visionOS-3D (immersive) variant: SwiftUI + Compositor Services shell driving the engine
# via ANGLE straight into the per-eye drawable textures. Swaps the UIKit shell (main.m) and 2D
# ANGLE window driver (vid_angle.m) for the immersive shell in Sources/immersive/.
if [ "${Q2_VISIONOS_3D:-0}" = "1" ]; then
  # Compile the immersive shell; drop the 2D UIKit entry point and window video driver.
  sed -i '' -e 's/          - "immersive"     .*/          - "main.m"\
          - "vid_angle.m"/' "$OUT"
  # Swift ↔ engine bridge, injected into the project-level settings.base (harmless on the
  # pure-C static-lib targets, which have no Swift).
  SET="$(mktemp)"; cat > "$SET" <<'YAML'
    SWIFT_VERSION: "5.0"
    SWIFT_OBJC_BRIDGING_HEADER: $(SRCROOT)/Sources/immersive/XRBridging.h
YAML
  sed -i '' -e "/^  base:$/r $SET" "$OUT"
  rm -f "$SET"
  # DISTINCT bundle id + display name so the 3D app is a SEPARATE install that never overwrites
  # the working 2D game (com.q2repro.q2repro). Two icons coexist; the game is never touched.
  sed -i '' \
    -e 's/PRODUCT_BUNDLE_IDENTIFIER: com.rebelancap.q2repro$/PRODUCT_BUNDLE_IDENTIFIER: com.rebelancap.q2repro3d/' \
    -e 's/^        CFBundleDisplayName: q2repro$/        CFBundleDisplayName: q2repro 3D/' \
    "$OUT"
  # Immersive frameworks on the app target + world-sensing usage string.
  sed -i '' \
    -e 's/^      - sdk: Metal.framework$/      - sdk: Metal.framework\
      - sdk: CompositorServices.framework\
      - sdk: SwiftUI.framework\
      - sdk: ARKit.framework/' \
    -e 's#^        LSSupportsOpeningDocumentsInPlace: true$#        LSSupportsOpeningDocumentsInPlace: true\
        NSWorldSensingUsageDescription: q2repro renders the game world locked to your head.#' \
    "$OUT"
  echo "retargeted $OUT for visionOS-3D (immersive SwiftUI + Compositor Services shell)"
fi

# ---- Q2_SIM=1: point the generated project's binary deps at SIMULATOR builds of ANGLE/
# FFmpeg/libcurl (arm64 sim slices) — the mandated pre-OTA simulator validation (CLAUDE.md
# REMOTE OPERATIONS). Composes with the variants above, so it rewrites the FINAL paths:
#   plain iOS            → angle-prebuilt-ios-sim      + work/ios-sim-deps
#   Q2_VISIONOS[_3D]=1   → angle-prebuilt-visionos-sim + work/xros-sim-deps
# Device builds are byte-identical when the flag is off.
if [ "${Q2_SIM:-0}" = "1" ]; then
  if [ "${Q2_VISIONOS:-0}" = "1" ]; then
    [ -d "$ROOT/spikes/angle-prebuilt-visionos-sim/libEGL.framework" ] || {
      echo "FATAL: xrsimulator ANGLE missing (build + stage to spikes/angle-prebuilt-visionos-sim)" >&2; exit 1; }
    ls "$ROOT"/work/xros-sim-deps/prefix/lib/libavcodec.a >/dev/null 2>&1 || {
      echo "FATAL: xrsimulator FFmpeg missing. Run: scripts/build-ffmpeg-visionos.sh simulator" >&2; exit 1; }
    ls "$ROOT"/work/xros-sim-deps/prefix/lib/libcurl.a >/dev/null 2>&1 || {
      echo "FATAL: xrsimulator libcurl missing. Run: scripts/build-curl-visionos.sh simulator" >&2; exit 1; }
    sed -i '' \
      -e 's#angle-prebuilt-visionos#angle-prebuilt-visionos-sim#g' \
      -e 's#work/xros-deps/prefix#work/xros-sim-deps/prefix#g' \
      "$OUT"
    echo "retargeted $OUT deps for the visionOS SIMULATOR (angle-prebuilt-visionos-sim, xros-sim-deps)"
  else
    [ -d "$ROOT/spikes/angle-prebuilt-ios-sim/libEGL.framework" ] || {
      echo "FATAL: simulator ANGLE missing. Run: scripts/build-angle-ios.sh simulator (+ stage to spikes/angle-prebuilt-ios-sim)" >&2; exit 1; }
    ls "$ROOT"/work/ios-sim-deps/prefix/lib/libavcodec.a >/dev/null 2>&1 || {
      echo "FATAL: simulator FFmpeg missing. Run: scripts/build-ffmpeg-ios.sh simulator" >&2; exit 1; }
    ls "$ROOT"/work/ios-sim-deps/prefix/lib/libcurl.a >/dev/null 2>&1 || {
      echo "FATAL: simulator libcurl missing. Run: scripts/build-curl-ios.sh simulator" >&2; exit 1; }
    sed -i '' \
      -e 's#angle-prebuilt-ios#angle-prebuilt-ios-sim#g' \
      -e 's#work/ios-deps/prefix#work/ios-sim-deps/prefix#g' \
      "$OUT"
    echo "retargeted $OUT deps for the iOS SIMULATOR (angle-prebuilt-ios-sim, ios-sim-deps)"
  fi
fi
