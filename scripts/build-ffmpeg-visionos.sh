#!/usr/bin/env bash
# Build FFmpeg static libs for visionOS arm64 — device (default) or simulator —
# mirrors build-ffmpeg-ios.sh but targets the XROS SDK (ogg music + cinematics via
# USE_AVCODEC). The five .a files are linked INDIVIDUALLY by the app (never merged —
# macOS `ar x` drops duplicate object basenames). One command; loud on failure.
#
#   scripts/build-ffmpeg-visionos.sh [device|simulator]
#
# device    → work/xros-deps/prefix      (SDK xros)
# simulator → work/xros-sim-deps/prefix  (SDK xrsimulator — pre-OTA sim validation)
set -euo pipefail

FFMPEG_VER=7.1
MIN_XROS=26.0
BUILD_ENV="${1:-device}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$BUILD_ENV" in
  device)    WORK="$ROOT/work/xros-deps";     SDK=xros;        TARGET="arm64-apple-xros$MIN_XROS" ;;
  simulator) WORK="$ROOT/work/xros-sim-deps"; SDK=xrsimulator; TARGET="arm64-apple-xros$MIN_XROS-simulator" ;;
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
echo "== configuring FFmpeg for visionOS arm64 $BUILD_ENV (target $TARGET) =="
./configure \
    --prefix="$PREFIX" \
    --enable-cross-compile --target-os=darwin --arch=arm64 \
    --cc="$CC" --sysroot="$SDKROOT" \
    --extra-cflags="-target $TARGET" \
    --extra-ldflags="-target $TARGET" \
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
# CODEC SYMBOLS, not the configure line — see the same block in build-ffmpeg-ios.sh for
# why. Short version: FFmpeg's configure silently ignores an unknown --enable-decoder
# name, and `idcinvideo` (the real name is `idcin`) disabled every .cin cinematic here
# with no diagnostic at configure, build, link or runtime.
# Symbol table read ONCE into a variable — never `nm | grep -q` under `set -o pipefail`,
# which SIGPIPEs nm on the match and fails the pipeline on the SUCCESS path.
SYMS="$(nm -gj "$PREFIX/lib/libavcodec.a" "$PREFIX/lib/libavformat.a" 2>/dev/null)"
for sym in ff_ogg_demuxer ff_theora_decoder ff_vorbis_decoder \
           ff_idcin_demuxer ff_idcin_decoder ff_pcm_u8_decoder; do
    case $'\n'"$SYMS"$'\n' in
        *$'\n'"_$sym"$'\n'*) ;;
        *) echo "MISSING SYMBOL $sym — a codec name in --enable-* is wrong"; fail=1 ;;
    esac
done
[ $fail -eq 0 ] || { echo "FFmpeg visionOS ($BUILD_ENV) build FAILED"; exit 1; }
echo "FFmpeg visionOS ($BUILD_ENV) libs OK in $PREFIX/lib"
