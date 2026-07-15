#!/usr/bin/env bash
# Build libcurl as a static lib for visionOS arm64 — device (default) or simulator —
# mirrors build-curl-ios.sh but targets the XROS SDK. HTTP-only, TLS via Apple
# SecureTransport (present on visionOS). Loud on failure.
#
#   scripts/build-curl-visionos.sh [device|simulator]
#
# device    → work/xros-deps/prefix
# simulator → work/xros-sim-deps/prefix  (SDK xrsimulator — pre-OTA sim validation)
set -euo pipefail
CURL_VER=8.11.0
MIN_XROS=26.0
BUILD_ENV="${1:-device}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$BUILD_ENV" in
  device)    WORK="$ROOT/work/xros-deps";     SYSROOT_ARGS=() ;;
  simulator) WORK="$ROOT/work/xros-sim-deps"; SYSROOT_ARGS=(-DCMAKE_OSX_SYSROOT=xrsimulator) ;;
  *) echo "usage: $0 [device|simulator]" >&2; exit 1 ;;
esac
PREFIX="$WORK/prefix"
SRC="$WORK/curl-$CURL_VER"

mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
    TARBALL="$ROOT/work/ios-deps/curl.tgz"          # download shared across envs
    if [ ! -f "$TARBALL" ]; then
        echo "== fetching curl $CURL_VER =="
        mkdir -p "$(dirname "$TARBALL")"
        curl -fSL "https://curl.se/download/curl-$CURL_VER.tar.gz" -o "$TARBALL"
    fi
    tar -xf "$TARBALL" -C "$WORK"
fi

cd "$SRC"
rm -rf "build-xros-$BUILD_ENV"
echo "== configuring libcurl for visionOS arm64 $BUILD_ENV (SecureTransport, HTTP-only) =="
cmake -B "build-xros-$BUILD_ENV" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=visionOS \
    "${SYSROOT_ARGS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_XROS" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DHTTP_ONLY=ON \
    -DCURL_USE_SECTRANSP=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF \
    -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DENABLE_UNIX_SOCKETS=OFF

echo "== building =="
cmake --build "build-xros-$BUILD_ENV" --config Release -j"$(sysctl -n hw.ncpu)"
cmake --install "build-xros-$BUILD_ENV" --config Release

a=$(find "$PREFIX/lib" -name "libcurl.a" | head -1)
[ -f "$a" ] && lipo -info "$a" | grep -q arm64 && echo "libcurl visionOS ($BUILD_ENV) OK: $a" || { echo "libcurl build FAILED"; exit 1; }
