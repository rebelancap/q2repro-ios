#!/usr/bin/env python3
"""Extract the engine source file lists from vendor/q2repro/meson.build so the
iOS Xcode app target stays in sync with upstream (D6: Xcode-native app build).

Parses the `common_src`, `client_src`, `refresh_src` arrays (which already include
the q2proto sources), keeps the .c files, and applies the iOS delta:
  - EXCLUDE desktop-only / dep-gated files not built for the M1 iOS config
    (SDL video/audio, http/curl, cinematics+ogg (FFmpeg), OpenAL) — these get
    re-added at later milestones.
  - ADD the portable unix bits we do need (system.c, hunk.c) — system.c is patched
    by the overlay to not define main() on iOS (we provide UIApplicationMain).
Prints one repo-relative path per line (relative to vendor/q2repro).

Usage: scripts/gen-ios-sources.py [--yaml]   (--yaml emits an xcodegen sources block)
"""
import re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
MESON = (ROOT / "vendor/q2repro/meson.build").read_text()

def array(name):
    m = re.search(name + r"\s*=\s*\[(.*?)\]", MESON, re.S)
    if not m:
        sys.exit(f"array {name} not found")
    return re.findall(r"'([^']+)'", m.group(1))

# --game: emit the vanilla game module sources (for the static-lib target),
# excluding shared files the engine target already compiles (avoids dup symbols).
if "--game" in sys.argv:
    gfiles = [f for f in array("game_src") if f.endswith((".c", ".cpp"))]
    GAME_EXCLUDE = {"src/shared/shared.c", "src/shared/base85.c", "src/shared/m_flash.c"}
    gfiles = [f for f in gfiles if f not in GAME_EXCLUDE]
    for f in gfiles:
        print(f"      - path: ../vendor/q2repro/{f}")
    sys.stderr.write(f"[gen-ios-sources] game: {len(gfiles)} sources "
                     f"(shared.c/base85/m_flash excluded — engine provides them)\n")
    sys.exit(0)

# --aqgame: Action Quake (aq2-tng) classic-API game module sources for its static
# lib. Self-contained (its own q_shared.c). All shared exports are renamed with an
# aq_ prefix (see --aqdefs) so nothing collides with the engine's shared.c.
if "--aqgame" in sys.argv:
    aqdir = ROOT / "vendor/aq2-tng/source"
    AQ_EXCLUDE = {"lcchack.c"}   # Windows DLLMain stub (_stdcall) — not built on iOS
    rels = [p.name for p in aqdir.glob("*.c") if p.name not in AQ_EXCLUDE]
    rels += ["acesrc/" + p.name for p in (aqdir / "acesrc").glob("*.c")]   # ACE/LTK bot AI
    rels = sorted(rels)
    for f in rels:
        print(f"      - path: ../vendor/aq2-tng/source/{f}")
    sys.stderr.write(f"[gen-ios-sources] aqgame: {len(rels)} Action Quake sources (incl. acesrc bots)\n")
    sys.exit(0)

# --aqdefs: emit GCC_PREPROCESSOR_DEFINITIONS lines renaming every top-level symbol
# defined in aq2-tng's q_shared.c to aq_<name>, so the game keeps its own classic
# shared implementations without colliding with the engine's identically-named ones.
if "--aqdefs" in sys.argv:
    aqdir = ROOT / "vendor/aq2-tng/source"
    qs = (aqdir / "q_shared.c").read_text(errors="ignore")
    qh = (aqdir / "q_shared.h").read_text(errors="ignore")
    names = set()
    for m in re.finditer(r'^[A-Za-z_][\w \t\*]*?\b([A-Za-z_]\w*)\s*\(', qs, re.M):
        n = m.group(1)
        if n not in ("if", "for", "while", "switch", "sizeof", "return"):
            names.add(n)
    for m in re.finditer(r'^(?:vec3_t|int|float|char|qboolean|byte)\s+([A-Za-z_]\w*)\b', qs, re.M):
        names.add(m.group(1))
    # Never rename a name that q_shared.h/.c maps to a libc function via a platform
    # `#define`/`#ifndef` (e.g. Q_strnicmp -> strncasecmp): pre-defining it on the
    # command line would disable that mapping AND skip its `#ifndef`-guarded fallback
    # definition, leaving the symbol undefined. Those map to libc → no engine collision.
    guarded = set(re.findall(r'^#\s*(?:define|ifndef)\s+([A-Za-z_]\w*)', qh, re.M))
    guarded |= set(re.findall(r'^#\s*ifndef\s+([A-Za-z_]\w*)', qs, re.M))
    names -= guarded
    # Strong-vs-strong globals that also exist in the engine/rerelease module (found at
    # link time; -fcommon can't merge these since neither side is a common symbol).
    names |= {"Sys_Error", "vtos", "itemlist", "ctf", "sv_airaccelerate"}
    for n in sorted(names):
        print(f"          - {n}=aq_{n}")
    sys.stderr.write(f"[gen-ios-sources] aqdefs: {len(names)} shared symbols renamed aq_* "
                     f"({len(guarded & (names | guarded))} libc-mapped names left as-is)\n")
    sys.exit(0)

# --rrgame: the C++ rerelease game module sources (for its static-lib target),
# from subprojects/rerelease-game/meson.build, plus jsoncpp; fmt is header-only.
if "--rrgame" in sys.argv:
    rr = (ROOT / "vendor/q2repro/subprojects/rerelease-game/meson.build").read_text()
    # src is assembled from multiple `src = [...]` / `src += [...]` blocks
    # (base + bots + ctf + rogue + xatrix).
    cpps = []
    for blk in re.findall(r"src\s*\+?=\s*\[(.*?)\]", rr, re.S):
        cpps += [f for f in re.findall(r"'([^']+)'", blk) if f.endswith(".cpp")]
    for f in cpps:
        print(f"      - path: ../vendor/q2repro/subprojects/rerelease-game/{f}")
    for j in ("json_reader.cpp", "json_value.cpp", "json_writer.cpp"):
        print(f"      - path: third_party/jsoncpp/lib_json/{j}")
    sys.stderr.write(f"[gen-ios-sources] rrgame: {len(cpps)} game .cpp + 3 jsoncpp\n")
    sys.exit(0)

# Base lists (q2proto sources live inside common_src).
files = []
for a in ("common_src", "client_src", "refresh_src"):
    files += array(a)

# M1 iOS config: keep only .c/.cpp; drop headers and files we don't build yet.
EXCLUDE = {
    # entry/main + desktop platform we replace or defer:
    "src/client/null.c",            # dedicated-server stub, not for client
}
keep = []
for f in files:
    if not f.endswith((".c", ".cpp")):
        continue
    if f in EXCLUDE:
        continue
    keep.append(f)

# Portable unix pieces we need (not in the base arrays; added via src/unix/meson.build).
# system.c: Sys_* + entry — overlay drops its main() on iOS. hunk.c: hunk allocator.
keep += ["src/unix/system.c", "src/unix/hunk.c"]

# M7 audio: the DMA sound mixer (meson gates it behind USE_SNDDMA via `client_src +=`,
# which the base-array parse above doesn't see). Our platform backend is the native
# CoreAudio driver app/Sources/snddma_coreaudio.m. (cin.c/ogg.c added with FFmpeg.)
keep += ["src/client/sound/dma.c"]

# M7 cinematics + ogg music (meson gates behind USE_AVCODEC via `client_src +=`).
# Needs the FFmpeg iOS static libs from scripts/build-ffmpeg-ios.sh.
keep += ["src/client/cin.c", "src/client/sound/ogg.c"]

# Phase 2 saves (meson gates behind USE_SAVEGAMES). Uses the rerelease game's JSON
# save API (ge->WriteGameJson etc.); registers save/load/autosave commands.
keep += ["src/server/save.c"]

# Phase 2 menu system (meson `ui_src`, gated behind USE_UI). The "main" menu comes
# from the q2pro.menu script (deploy to baseq2/). Built-in menus are C-coded.
keep += ["src/client/ui/" + f for f in
         ("ui.c", "menu.c", "script.c", "demos.c", "playerconfig.c",
          "playermodels.c", "servers.c", "mapdb.c")]

# HTTP (libcurl) for the multiplayer server browser's master queries (USE_CURL).
keep += ["src/client/http.c"]

# De-dup, stable order.
seen = set(); ordered = []
for f in keep:
    if f not in seen:
        seen.add(f); ordered.append(f)

if "--yaml" in sys.argv:
    print("      # generated by scripts/gen-ios-sources.py from meson.build")
    for f in ordered:
        print(f"      - path: ../vendor/q2repro/{f}")
else:
    for f in ordered:
        print(f)

sys.stderr.write(f"[gen-ios-sources] {len(ordered)} source files "
                 f"(FFmpeg/OpenAL/curl/SDL excluded for M1)\n")
