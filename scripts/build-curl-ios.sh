#!/usr/bin/env bash
# Build libcurl as a static lib for iOS arm64 — device (default) or simulator —
# enables the multiplayer server browser's HTTP master queries (USE_CURL). HTTP-only,
# TLS via Apple SecureTransport (no OpenSSL), per the prior port's proven iOS recipe.
# Loud on failure.
#
#   scripts/build-curl-ios.sh [device|simulator]
#
# device    → work/ios-deps/prefix
# simulator → work/ios-sim-deps/prefix  (arm64 sim slice — for the mandated pre-OTA
#             simulator validation, CLAUDE.md REMOTE OPERATIONS)
set -euo pipefail
CURL_VER=8.11.0
MIN_IOS=15.0
BUILD_ENV="${1:-device}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "$BUILD_ENV" in
  device)    WORK="$ROOT/work/ios-deps";     SYSROOT_ARGS=() ;;
  simulator) WORK="$ROOT/work/ios-sim-deps"; SYSROOT_ARGS=(-DCMAKE_OSX_SYSROOT=iphonesimulator) ;;
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
rm -rf "build-ios-$BUILD_ENV"
echo "== configuring libcurl for iOS arm64 $BUILD_ENV (SecureTransport, HTTP-only) =="
cmake -B "build-ios-$BUILD_ENV" -G "Unix Makefiles" \
    -DCMAKE_SYSTEM_NAME=iOS \
    ${SYSROOT_ARGS[@]+"${SYSROOT_ARGS[@]}"} \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_IOS" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DHTTP_ONLY=ON \
    -DCURL_USE_SECTRANSP=ON -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF \
    -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DUSE_LIBIDN2=OFF \
    -DCURL_ZLIB=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DENABLE_UNIX_SOCKETS=OFF

echo "== building =="
cmake --build "build-ios-$BUILD_ENV" --config Release -j"$(sysctl -n hw.ncpu)"
cmake --install "build-ios-$BUILD_ENV" --config Release

a=$(find "$PREFIX/lib" -name "libcurl.a" | head -1)
[ -f "$a" ] && lipo -info "$a" | grep -q arm64 && echo "libcurl iOS ($BUILD_ENV) OK: $a" || { echo "libcurl build FAILED"; exit 1; }
