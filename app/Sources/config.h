/*
 * iOS M1 config for q2repro (Xcode-native build, D6).
 * Trimmed to the M1 dependency set: zlib only (iOS SDK libz). FFmpeg/OpenAL/curl/
 * SDL/png/jpeg OFF — base1 uses built-in WAL/PCX/TGA. Re-enabled at later milestones.
 *
 * IMPORTANT: meson sets *conditional* feature macros only when enabled, and the
 * code checks several with #ifdef (e.g. sound/mem.c: #ifdef USE_AVCODEC). So a
 * disabled conditional feature must be LEFT UNDEFINED, never `#define ... 0`.
 * Unconditional toggles (config.set10 always) are #if-checked and defined 0/1.
 */
#pragma once

#define BASEGAME "baseq2"
#define BUILDSTRING "iOS"
#define CPUSTRING "arm64"
#define DATADIR "."
#define DEFGAME ""
#define DEFGLPROFILE "es3.0"      /* native EAGL ES 3.0 (D3) */

#define HAVE_MALLOC_H 0
#define HAVE_MEMCCPY
#define HAVE_STRCHRNUL
#define HAVE_STRNLEN
#define HAVE_BACKTRACE 0

#define HOMEDIR ""
#define LIBDIR "."
#define REVISION 4607
#define VERSION "r4607~1523f113-ios"
#define R_TEXTURE_FORMATS "png tga"

#define VID_GEOMETRY "640x480"
#define VID_MODELIST "640x480 800x600 1024x768"

/* --- unconditional toggles (always defined 0/1; #if-checked) --- */
#define USE_AUTOREPLY 1
#define USE_DEBUG 0
#define USE_FPS 0
#define USE_GLES 0            /* NOT the legacy GLES1 path; ES3 is runtime-detected */
#define USE_ICMP 0
#define USE_LITTLE_ENDIAN 1
#define USE_MD3 1
#define USE_MD5 1
#define USE_MEMORY_TRACES 0
#define USE_PACKETDUP 0
#define USE_PNG 1        /* rerelease assets are PNG (conchars.png, hi-res textures) */
#define USE_PROTOCOL_EXTENSIONS 1
#define USE_TGA 1
#define USE_ZLIB 1

/* --- conditional features, OFF for M1 ---
 * Only USE_AVCODEC / USE_NEW_GAME_API are checked with #ifdef/defined() (verified
 * by grep), so those MUST stay UNDEFINED. Every other off feature is #if- or
 * value-used (e.g. `!USE_MVD_CLIENT` in server/entities.c:781) and must be 0. */
#define USE_CURL 1   /* MP server browser HTTP master queries (libcurl, SecureTransport) */
#define USE_JPG 0
#define USE_OPENAL 0
#define USE_SDL 0
#define USE_SNDDMA 1   /* M7: native CoreAudio (RemoteIO) DMA backend, app/Sources/snddma_coreaudio.m */
#define USE_UI 1   /* Phase 2: menu system (client/ui/*, q2pro.menu script) */
#define USE_MVD_CLIENT 0
#define USE_MVD_SERVER 0
#define USE_SAVEGAMES 1   /* Phase 2: campaign saves/load (server/save.c; rerelease JSON save API) */
#define USE_SYSCON 0
#define USE_CLIENT_GTV 0
#define USE_AVCODEC 1  /* M7: FFmpeg 7.1 static (scripts/build-ffmpeg-ios.sh) → ogg music + cinematics */
/* left UNDEFINED (must not be 0): USE_NEW_GAME_API */
