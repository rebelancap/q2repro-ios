/* Minimal config.h for the rerelease game static-lib target (mirrors the game's
 * meson-generated config.h: only REVISION/VERSION/CPUSTRING). Its own include
 * dir — kept off the engine target's path so the two config.h files don't clash. */
#pragma once
#define REVISION  4607
#define VERSION   "r4607~1523f113-ios"
#define CPUSTRING "arm64"
