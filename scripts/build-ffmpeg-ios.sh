#!/usr/bin/env bash
# Build FFmpeg as static libs for iOS arm64 — device (default) or simulator — enables
# ogg music (ogg.c) and cinematics (cin.c) via USE_AVCODEC. One command; loud on failure.
#
#   scripts/build-ffmpeg-ios.sh [device|simulator]
#
# device    → work/ios-deps/prefix      (SDK iphoneos)
# simulator → work/ios-sim-deps/prefix  (SDK iphonesimulator, arm64 sim slice — for the
#             mandated pre-OTA simulator validation, CLAUDE.md REMOTE OPERATIONS)
#
# Recipe adapted from the prior port's proven-on-device build (FFmpeg 7.1, minimal
# codec set). The five .a files are linked INDIVIDUALLY by the app (OTHER_LDFLAGS +
# LIBRARY_SEARCH_PATHS) — NOT merged. macOS `ar x` flattens duplicate object
# basenames (FFmpeg reuses e.g. utils.o across libs) and silently drops objects, so
# a merged archive would be broken; the Apple linker handles duplicates across
# separate archives fine, so we never merge.
set -euo pipefail

FFMPEG_VER=7.1
MIN_IOS=15.0
BUILD_ENV="${1:-device}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$BUILD_ENV" in
  device)    WORK="$ROOT/work/ios-deps";     SDK=iphoneos;        VERMIN="-miphoneos-version-min=$MIN_IOS" ;;
  simulator) WORK="$ROOT/work/ios-sim-deps"; SDK=iphonesimulator; VERMIN="-mios-simulator-version-min=$MIN_IOS" ;;
  *) echo "usage: $0 [device|simulator]" >&2; exit 1 ;;
esac
PREFIX="$WORK/prefix"
SRC="$WORK/ffmpeg-$FFMPEG_VER"
NCPU="$(sysctl -n hw.ncpu)"

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CC="$(xcrun --sdk "$SDK" -f clang)"

mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
    TARBALL="$ROOT/work/ios-deps/ffmpeg.tar.xz"     # download shared across envs
    if [ ! -f "$TARBALL" ]; then
        echo "== fetching FFmpeg $FFMPEG_VER =="
        mkdir -p "$(dirname "$TARBALL")"
        curl -fSL "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz" -o "$TARBALL"
    fi
    tar -xf "$TARBALL" -C "$WORK"
fi

cd "$SRC"
echo "== configuring FFmpeg for iOS arm64 $BUILD_ENV (min $MIN_IOS) =="
./configure \
    --prefix="$PREFIX" \
    --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="$CC" --sysroot="$SDKROOT" \
    --extra-cflags="-arch arm64 $VERMIN" \
    --extra-ldflags="-arch arm64 $VERMIN" \
    --enable-static --disable-shared --enable-pic \
    --disable-programs --disable-doc --disable-debug \
    --disable-avdevice --disable-avfilter --disable-network \
    --disable-everything \
    --enable-demuxer=ogg,idcin,wav,flac,mp3 \
    --enable-decoder=theora,vorbis,idcin,pcm_u8,pcm_s16le,flac,mp3,opus \
    --enable-parser=vorbis \
    --enable-protocol=file \
    --disable-audiotoolbox --disable-videotoolbox \
    --disable-iconv --disable-bzlib --disable-lzma \
    --enable-swscale --enable-swresample

echo "== building (make -j$NCPU) =="
make -j"$NCPU"
make install

echo "== verify =="
fail=0
for l in libavcodec libavformat libavutil libswresample libswscale; do
    a="$PREFIX/lib/$l.a"
    if [ ! -f "$a" ]; then echo "MISSING $a"; fail=1; continue; fi
    lipo -info "$a" | grep -q arm64 || { echo "$a not arm64"; fail=1; }
done
# CODEC SYMBOLS, not the configure line. `--disable-everything` makes every capability
# opt-in BY NAME, and FFmpeg's configure does NOT fail on an unknown --enable-decoder
# name — it records `!CONFIG_<NAME>_DECODER=yes` and builds happily without it. That is
# how `idcinvideo` (not a real FFmpeg name; the id CIN video decoder is `idcin`) sat in
# this script silently disabling every original-baseq2 .cin cinematic: SCR_InitCinematics
# needs BOTH av_find_input_format("idcin") AND avcodec_find_decoder(AV_CODEC_ID_IDCIN),
# so the whole .cin format was struck from the supported list with no diagnostic anywhere.
#   ff_ogg_demuxer   + ff_theora_decoder → .ogv cinematics (rerelease) + ogg music
#   ff_idcin_demuxer + ff_idcin_decoder  → .cin cinematics (original baseq2, mission packs)
#   ff_vorbis_decoder                    → ogg music, and .ogv cinematic audio
#   ff_pcm_u8_decoder                    → .cin cinematic audio
# Read the symbol table ONCE into a variable. Do not pipe nm into `grep -q`: this script
# runs under `set -o pipefail`, and `grep -q` exits the moment it matches, which SIGPIPEs
# nm and makes the whole pipeline report failure — on the SUCCESS path, so every symbol
# looks missing exactly when they are all present.
SYMS="$(nm -gj "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavformat.a" 2>/dev/null)"
for sym in ff_ogg_demuxer ff_theora_decoder ff_vorbis_decoder \
           ff_idcin_demuxer ff_idcin_decoder ff_pcm_u8_decoder; do
    case $'\n'"$SYMS"$'\n' in
        *$'\n'"_$sym"$'\n'*) ;;
        *) echo "MISSING SYMBOL $sym — a codec name in --enable-* is wrong"; fail=1 ;;
    esac
done
[ $fail -eq 0 ] || { echo "FFmpeg iOS ($BUILD_ENV) build FAILED"; exit 1; }
echo "FFmpeg iOS ($BUILD_ENV) libs OK in $PREFIX/lib"
