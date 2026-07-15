# Graphics substrate decision (iOS)

Phase 0.4 deliverable. Decide the GL substrate with data, not inheritance.
Candidates: (a) native EAGL GLES 3.0, (b) ANGLE (ES 3.1+ translated to Metal),
(c) anything better. Plus SDL2 vs SDL3.

## The deciding constraint: MD5 rerelease models

q2repro's renderer runs on **OpenGL ES 3.0 as-is** — every core effect (dynamic
lights, bloom, underwater warp, fog, sky, particles, MD2/MD3 GPU vertex-lerp) is
ES-3.0-clean (see `frame-flow.md` renderer facts). The **single** feature that
native ES 3.0 forfeits is **MD5 rerelease high-detail *animated* models**, whose
GPU skeletal skinning requires **SSBO (ES 3.1)** or a **buffer texture (ES 3.2)**.
`models.c:1683-1714` forces `use_gpu_lerp` when client-side vertex arrays are
absent (always true on ES ≥3.0) and, finding neither SSBO nor buffer texture,
**disables `gl_md5_load` entirely** — there is no CPU-skinning fallback. MD5 models
are an explicit Phase-2 acceptance item, so **native ES 3.0 fails a hard
requirement.**

## Data

### Source analysis (capability table, `qgl.c`)
| Cap | Requires | Native EAGL ES 3.0 | ANGLE ES 3.1 |
|-----|----------|--------------------|--------------|
| `QGL_CAP_SHADER` (UBO) | GL 3.1 / ES 3.0 | ✅ | ✅ |
| `QGL_CAP_SHADER_STORAGE` (SSBO) | GL 4.3 / **ES 3.1** | ❌ | ✅ **← unblocks MD5** |
| `QGL_CAP_BUFFER_TEXTURE` | GL 3.1 / **ES 3.2** | ❌ | ❌ (unneeded; SSBO preferred) |
| MD5 GPU skeletal | SSBO **or** buffer texture | ❌ **disabled** | ✅ |

### On-device empirical (ES3Probe spike, 2026-07-08)
Confirmed on the **actual iPhone Air (A19 Pro, iOS 27)** — `artifacts/es3probe-device.log`:
```
GL_VERSION:  OpenGL ES 3.0 Metal - 105     GL_RENDERER: Apple A19 Pro GPU
drawable: 2736x1260 @3x   screen.maxFPS: 120   MAX_TEXTURE_SIZE: 16384   MAX_UBO_BINDINGS: 24
SSBO(ES3.1): NO   buffer_texture(ES3.2): NO   =>  MD5 GPU-skeletal capable: NO
anisotropic: YES   notable ext: ASTC (astc_ldr), GL_EXT_shader_framebuffer_fetch
```
This **empirically confirms on hardware** the source analysis: native EAGL ES 3.0
cannot GPU-skin MD5. It also confirms EAGL ES 3.0 still *functions* on iOS 27 (now
implemented over Metal — "OpenGL ES 3.0 Metal"): context created, ES 3.00 shaders
compiled, triangle rendered, CADisplayLink drove frames at up to 120 Hz. Deprecated
but not yet removed. (Simulator run agreed: `OpenGL ES 3.0 APPLE-24.0.1`, SSBO NO.)

### On-device empirical (ANGLE-Metal caps probe) — THE PIVOTAL RESULT
ANGLE 2.1.1 Metal backend, queried directly on this Mac (the `DisplayMtl.mm` caps
code is shared with iOS, so the verdict transfers). `artifacts/angle-metal-caps.txt`:
```
ES 3.1 context: REFUSED (EGL_BAD_MATCH)  → ANGLE-Metal does not expose ES 3.1
ES 3.0 context: OK
GL_VERSION:  OpenGL ES 3.0 (ANGLE 2.1.1)
GL_RENDERER: ANGLE (Apple, ANGLE Metal Renderer: Apple M4 Pro)
GL_EXT/OES_texture_buffer: absent   shader_storage / compute: absent
ANGLE-Metal can run q2repro MD5 GPU skeletal: NO
```
Source confirms why: `DisplayMtl.mm:857-861` hardcodes `maxPerStageStorageBuffers = 0`
(`// NOTE(hqle): support storage buffer.`) and there is no texture-buffer/compute
support anywhere in the Metal backend. **ANGLE-on-Metal caps at ES 3.0 and cannot
run MD5 GPU skinning** — it is *not* the SSBO escape hatch the source-gating
analysis suggested. (That analysis assumed ES 3.1 ⇒ SSBO; true for ANGLE's *Vulkan*
backend, false for its *Metal* backend.)

### The macOS oracle data point
The oracle runs desktop **GL 3.2 core** (macOS caps at 4.1 → no SSBO) and gets MD5
via the **buffer-texture** path. iOS has no buffer texture until ES 3.2, so the
oracle's route isn't available to us — SSBO via ES 3.1 (ANGLE) is.

## Decision — D3 (revised with data): ES 3.0 substrate + CPU-skinning for MD5

The premise "ANGLE ES 3.1 unblocks MD5 via SSBO" is **false for ANGLE's Metal
backend** (proved above: ES 3.0 max, no SSBO/TBO/compute). So the substrate choice
splits into two independent questions:

**(1) How do we get MD5 (a Phase-2 requirement) at all?** No ES-3.0 path on iOS —
native EAGL *or* ANGLE-Metal — provides GPU skeletal skinning. The realistic options:
| Option | MD5 | Cost / risk |
|--------|-----|-------------|
| **CPU skinning** (renderer overlay: skin MD5 verts on CPU, emit to the streamed VBO) | ✅ | Moderate, contained patch. Q2 MD5 models are a few thousand verts × a handful on-screen → cheap on A-series CPU. **Chosen.** |
| ANGLE **Vulkan** backend on MoltenVK (ES→Vulkan→Metal) | ✅ (real SSBO) | Heavy 3-layer stack, uncertain iOS support, likely slower than native. Reserve as a measured escalation only if CPU skinning proves too costly. |
| Wait for ANGLE-Metal SSBO (`DisplayMtl.mm` TODO) | ✅ later | Not available now; not a plan. |

→ **MD5 = CPU-skinning overlay**, independent of the base context choice.

**(2) What base ES 3.0 context?** Both candidates are ES 3.0 with identical
q2repro-relevant features; the trade is complexity vs longevity:
| | Native EAGL ES 3.0 | ANGLE-Metal ES 3.0 |
|--|--------------------|--------------------|
| Works on iOS 26 today | ✅ (probe-confirmed) | ✅ (probe-confirmed) |
| Extra moving parts | none (UIKit+EAGL) | EGL layer + embed/sign `libEGL`/`libGLESv2` frameworks |
| Apple GLES deprecation risk | exposed (dead-ends if EAGL removed) | insulated (Metal underneath) |
| GPU tooling | deprecated GL capture | Metal System Trace / GPU capture |

**Chosen: start on native EAGL ES 3.0 + CPU-skinning MD5** — the fastest, lowest-risk
route to a fully-featured port that works on iOS 26 today. **Keep ANGLE-Metal as a
documented, low-cost drop-in** (the engine is context-agnostic through `qgl`; both
are ES 3.0, so swapping later is cheap) for when GLES deprecation bites or when we
want Metal tooling. The ANGLE iOS frameworks are already built and archived
(`spikes/angle/out/ios-arm64-device/`), so the swap is ready when wanted.

**Why not lead with ANGLE anyway?** Its headline benefit (MD5 via SSBO) evaporated;
what remains (future-proofing, tooling) doesn't justify the EGL/framework complexity
on the critical path to a shipping port. Revisit if native EAGL hits a wall.

**Open items (measured, not assumed):**
- ✅ Native EAGL ES 3.0 confirmed working on-device (ES3Probe on A19 Pro). ES-3.0
  *engine* perf floor still to come once q2repro itself runs on device (Phase 1).
- Implement + measure the CPU-skinning MD5 overlay; if its cost is unacceptable at
  target frame rate, escalate to the ANGLE-Vulkan/MoltenVK evaluation.
- `mediump` precision in fog/dlight/world-position math (`shader.c:57-70`) — promote
  to `highp` if banding/wobble appears on-device.

## Decision — D4: native UIKit + EAGL (no SDL)

With the base context on **native EAGL ES 3.0**, the video/input/audio backend is a
native UIKit shell implementing `vid_driver_t` directly: UIKit window +
`CAEAGLLayer` + `CADisplayLink` (one present per served tick, per `pacing.md`),
`GameController.framework` for controllers, `AVAudioSession` + OpenAL/DMA for audio.
This is *simpler* than the SDL path and gives exact control over pacing and the iOS
lifecycle. (If we later swap to ANGLE-Metal, only the context/present creation
changes — EGL on a `CAMetalLayer` — everything else stays.)

- SDL is off the critical path. If ever wanted for quick controller/input bring-up,
  prefer **SDL3** (maintained; EGL/ANGLE + Metal; better high-DPI) over SDL2, but
  adopting it is a full rewrite of `sdl.c` regardless (renamed drawable-size / mouse
  / gamma / audio APIs). Datum: macOS "sdl2" is already sdl2-compat/SDL3.

**Net:** native UIKit + EAGL ES 3.0; CPU-skinning overlay for MD5; ANGLE-Metal
frameworks kept in reserve as a proven drop-in.

## Status
- ANGLE iOS (arm64, Metal) frameworks: **built** (`spikes/angle/out/ios-arm64-device/`,
  arm64, platform iOS, Metal backend). Kept as the reserve substrate.
- ANGLE-Metal caps: **probed, ES 3.0 / no SSBO / no MD5** (`artifacts/angle-metal-caps.txt`).
- Native EAGL ES 3.0: **confirmed on-device** (iPhone Air / A19 Pro / iOS 27; ES3Probe).
- Device pipeline (build→sign→install→launch→capture) proven end-to-end.
- Next: Phase 1 bring-up on native EAGL (static-link game per D5, native
  `vid_driver_t`), then the CPU-skinning MD5 overlay with measurements.
