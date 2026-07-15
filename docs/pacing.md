# Presentation & pacing design (iOS)

Phase 0.5 deliverable. How the iOS port drives the loop and presents exactly one
frame per display refresh, on 60 Hz and ProMotion (120 Hz) panels, and how we
verify it. Grounded in the upstream loop model (see `frame-flow.md`).

## The invariant

**Exactly one `vid->swap_buffers()` per rendered frame, one rendered frame per
display refresh we choose to serve.** Upstream already presents exactly once, at
the end of `R_EndFrame()` (`refresh/main.c:940`). The iOS risk is not double
presenting inside the engine — it's the *loop driver* and *present timing*, which
we own. The prior port's "weapon micro-jitter" is a pacing symptom (interpolation
clock vs present cadence), so pacing is a first-class correctness concern, not a
polish item.

## Who drives the loop

Desktop runs `while(!terminate) Qcommon_Frame()` (`unix/system.c:585`) — the
process owns the loop. **iOS inverts this**: the OS owns the run loop and calls us
via **CADisplayLink**. Design:

- A single `CADisplayLink` attached to the main run loop, its callback runs **one**
  `Qcommon_Frame()`. The display link fires in lockstep with the display's refresh
  (and reports `targetTimestamp`), so its cadence *is* our present cadence.
- **Neutralize the sub-1 ms busy-spin** in `Qcommon_Frame` (`common.c:1102-1113`).
  On desktop it guarantees ≥1 ms elapsed between frames; under a display-link that
  already spaces calls by 8.3–16.7 ms it normally exits immediately, but it must
  never spin (it would burn the render thread). The `com_timedemo` branch already
  skips it — we relax the same condition on iOS (or gate on a `com_eventTime`
  already ≥1 ms ahead). One display-link tick → one engine frame, full stop.
- **Do not add sleeps inside `Qcommon_Frame`.** Pacing comes from the display link
  (and, in ASYNC_VIDEO, the GPU fence), never from a timer we insert.
- If cinematic/OGG decode (main-thread, `cin.c`/`ogg.c`) ever risks overrunning a
  refresh, that's a decode-cost problem to profile — not a reason to present twice.

## 60 Hz vs ProMotion (120 Hz)

Two axes: **what refresh rate we ask for**, and **how the engine's integer-ms clock
copes**.

1. **Requesting the cadence.** `CADisplayLink.preferredFrameRateRange` selects the
   served rate. Default plan: request the display's native max (120 on ProMotion,
   60 otherwise) and *serve every tick* only if we sustain it; otherwise request a
   stable 60 and serve every tick. A half-rate ProMotion mode (60 on a 120 panel)
   is a clean fallback that still presents once per served tick. `Info.plist`
   `CADisableMinimumFrameDurationOnPhone=YES` is required to unlock >60 Hz.
2. **The integer-ms clock.** Upstream time is integer ms (`Sys_Milliseconds`,
   `CLOCK_MONOTONIC`). 120 Hz = 8.33 ms/frame, which aliases against 1 ms steps
   (8,8,9,8,8,9…). For *simulation* this is harmless (server tick is 25 ms; client
   interpolation reads `cl.time`). For *pacing decisions* that compare ms budgets
   (`r_maxfps` gating) it causes jitter at 120 Hz. Mitigation: prefer **ASYNC_VIDEO**
   pacing (fence-gated, no ms-budget compare) at 120 Hz, and treat any move to a
   sub-ms `Sys_Milliseconds` as a deliberate, measured change (it touches the whole
   sim) — not a casual patch. Recorded as an open item if 120 Hz pacing needs it.

## Which pacing mode

Upstream `sync_mode` (`client/main.c:3121`) options relevant to iOS:

| Mode | cvar | Behavior | iOS fit |
|------|------|----------|---------|
| `SYNC_MAXFPS` | `cl_async 0` | render+physics locked to `cl_maxfps` | simplest; ties render rate to a ms cap — aliases at 120 Hz |
| `ASYNC_FULL` | `cl_async 1` (default) | physics at `cl_maxfps`, render at `r_maxfps` (0 = every iter) | good default; render every display-link tick |
| `ASYNC_VIDEO` | `cl_async 2` | physics at `cl_maxfps`, **render gated by GPU fence** `R_VideoSync()` | **ProMotion-friendly**; fence (not a ms timer) decides when the prior present retired. `qglFenceSync` exists on ES 3.0/ANGLE so this is reachable. |

**Plan:** default the port to **`cl_async 1`** (render one frame per display-link
tick, physics decoupled at `cl_maxfps` — matches desktop feel), and **benchmark
`cl_async 2`** head-to-head at 120 Hz for pacing smoothness. `SDL_GL_SetSwapInterval`
is a no-op on iOS (present is display-link driven), so `swap_interval` is a stub —
vsync is enforced structurally by presenting once per CADisplayLink callback.

## How we verify pacing (before trusting feel)

1. **One-present-per-tick proof.** Xcode GPU capture / Metal System Trace: confirm
   exactly one `present`/`CAContext` commit per CADisplayLink period. Any frame with
   0 or 2 presents is a bug.
2. **Frame-time distribution, not just fps.** The timedemo fps line is an average;
   the jitter lives in the tail. Capture per-frame present intervals (Instruments
   *Core Animation FPS* / *Metal System Trace*, or a lightweight ring buffer around
   `vid->swap_buffers` dumped post-run — never printed inside a measured run). Report
   p50/p95/p99 of the present interval; target p95 within one refresh period.
3. **Deterministic input harness.** Use the recorded intro/benchmark demo
   (lerpfrac pinned to 1 in timedemo) so view/weapon motion is identical run to run;
   this isolates *render-pacing* jitter from *interpolation* jitter. Side-by-side
   slow-motion screen recordings (240 fps) of device vs macOS oracle at matched
   cvars are a legitimate instrument for the weapon-view jitter specifically.
4. **Sustained, not peak.** Judge against a multi-minute run at native drawable
   resolution — thermal throttle and background eviction show up only over time.

## Open pacing questions (tracked)

- Does 120 Hz require a sub-ms `Sys_Milliseconds` to stop budget-compare aliasing,
  or does ASYNC_VIDEO make it moot? Decide with a measured 120 Hz frame-time trace.
- `cl_async 1` vs `2` on device — which gives the flatter p95 present interval?
- Audio underrun margin: does keeping `S_Update` on every served tick hold
  `s_mixahead` (100 ms) under worst-case cinematic decode? Measure on device.
