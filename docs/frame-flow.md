# q2repro — how a frame flows from input to present

Phase 0.1 deliverable. Synthesized from a full read of the vendored upstream
(`vendor/q2repro`, pinned `1523f113`). File:line citations are into that tree.
This is the map the iOS port is built against; the seams called out here are
where the port attaches.

## One-paragraph summary

The **process owns the loop**: `main()` (`src/unix/system.c:560`) runs
`while(!terminate) Qcommon_Frame()` with no sleep of its own. Each
`Qcommon_Frame()` (`src/common/common.c:1067`) measures elapsed ms (busy-spinning
until ≥1 ms), runs the **server tick** `SV_Frame` (40 Hz for rerelease) and the
**client frame** `CL_Frame`. `CL_Frame` pumps input, advances sim/interpolation,
and — *at most once per outer iteration*, gated by a `ref_frame` boolean — calls
`SCR_UpdateScreen` → `R_RenderFrame` → `R_EndFrame`, whose final act is the
**single present** `vid->swap_buffers()` (`src/refresh/main.c:940`). Physics-only
iterations render nothing. Everything platform-specific is behind one 24-slot
`vid_driver_t` vtable (`inc/client/video.h:21`).

## The pipeline, stage by stage

```
 CADisplayLink (iOS)  ─or─  while(!terminate) (desktop)   ← LOOP DRIVER  (port replaces this)
        │
        ▼
 Qcommon_Frame()                                    common.c:1067
   ├─ Com_CompleteAsyncWork()  (bg loader done-queue)      :1081
   ├─ msec = Sys_Milliseconds() - oldtime  (CLOCK_MONOTONIC, integer ms)  system.c:86
   ├─ busy-spin: while(msec<1) CL_ProcessEvents()          :1102   ← NEUTRALIZE on iOS
   ├─ clamp hitch (msec>250 → 100); apply timescale/fixedtime
   ├─ SV_Frame(msec)   → runs a game tick only on 25 ms boundaries   server/main.c:1844
   └─ CL_Frame(msec)                                       client/main.c:3273
        ├─ CL_ProcessEvents() → vid->pump_events()  (input; may pump many×/frame)
        ├─ switch(sync_mode){…}  decides phys_frame / ref_frame     :3288
        ├─ CL_DemoFrame / CL_SetClientTime  (advance cl.time, lerpfrac)
        ├─ CL_SendCmd / CL_PredictMovement  (client-side prediction — feel)
        ├─ SCR_RunCinematic()  (FFmpeg decode on THIS thread)   cin.c:454
        └─ if (ref_frame):
             SCR_UpdateScreen()                             screen.c:2090
               └─ R_BeginFrame → SCR_DrawActive (3D view) → UI_Draw → Con_Draw
                    └─ R_RenderFrame()                      refresh/main.c:803
                         world → entities → beams → particles → flares
                         → FBO post (bloom / underwater warp) → 2D → polyblend
               └─ R_EndFrame()                              refresh/main.c:919
                    └─ vid->swap_buffers()   ★ THE ONE PRESENT ★    main.c:940
                    └─ (opt) qglFenceSync  when cl_async>1          main.c:942
             S_Update()  (audio: set listener, mix ring)   sound/main.c:902
```

## The seams the iOS port attaches to

| Seam | Upstream | iOS action |
|------|----------|------------|
| **Loop driver** | `while(!terminate)` `system.c:585` | Replace with a CADisplayLink tick calling `Qcommon_Frame()`; **neutralize the `msec<1` busy-spin** (`common.c:1102`) so one tick = one frame and the display link paces. |
| **Present** | `vid->swap_buffers` = `SDL_GL_SwapWindow` `sdl.c:96` | Implement as EAGL `presentRenderbuffer:` / ANGLE `eglSwapBuffers`. Exactly one per rendered frame. |
| **Video driver** | `vid_driver_t` `video.h:21` (24 callbacks) | One struct: init/shutdown, `get_proc_addr`, `swap_buffers`, `swap_interval` (no-op on iOS), `pump_events`, `set_mode`, `get_dpi_scale`, mouse stubs. |
| **GL context** | SDL requests profile+version from `R_GetGLConfig()` `main.c:1484` | Create ES 3.x context (native EAGL or ANGLE-on-Metal); feed **drawable pixel size** to `R_ModeChanged` (`sdl.c:127`). |
| **Input** | keyboard/mouse via SDL events `sdl.c:481` | Greenfield: touch + `GameController.framework`. **No controller or text-input code exists upstream** (grep-verified). |
| **Audio** | main-thread mix → ring; audio-thread pull `dma.c` + `unix/sound/sdl.c` | Implement `begin_painting/submit/activate`; wire `Activate()` to `AVAudioSession` + scene lifecycle. Render hitch >`s_mixahead` (100 ms) underruns. |
| **Game module** | dlopen `game_arm64.dylib` `gamedll.c:76` | **Static-link** the rerelease game into the app; replace `GameDll_Load` with a direct entry-point call (iOS forbids dlopen of external code). |
| **Lifecycle** | SDL focus → `CL_Activate` `sdl.c:348` | Map `didEnterBackground`/`willEnterForeground`/audio-interruption → `CL_Activate`; stop display link while backgrounded. |

## Timing & pacing facts (drive Phase 0.5)

- Time base is **integer milliseconds** (`Sys_Milliseconds`, `CLOCK_MONOTONIC`). 120 Hz = 8.33 ms aliases against 1 ms granularity — a deliberate concern for ProMotion.
- Rerelease server tick = **40 Hz / 25 ms** (`sv_fps 40`, latched); `Com_ComputeFrametime` → framediv 4. Gameplay view math is authored to be tickrate-invariant (frame-time-scaled) — keep 25 ms exact.
- Rerelease forces `cl.frametime.div = 1` (`parse.c:736`): gun/kick/viewoffset are lerped at **40 Hz across single ticks**. The prior port's "weapon micro-jitter" is therefore an **interpolation-clock / present-pacing** problem, not a math problem. The intro/timedemo (lerpfrac pinned to 1) isolates render-pacing jitter from interpolation jitter.
- Pacing modes (`sync_mode`, `main.c:3121`): `SYNC_MAXFPS` (cl_async 0), `ASYNC_FULL` (cl_async 1, default), `ASYNC_VIDEO` (cl_async 2, GPU-fence gated — **the ProMotion-friendly path**, reachable on iOS because `qglFenceSync` exists on ES 3.0). `SYNC_TIMEDEMO` disables all gating.
- **Benchmark line to scrape:** `"%u frames, %3.1f seconds: %3.1f fps"` (`demo.c:1504`). No built-in percentiles — capture frame-time distribution with Instruments or an external hook.

## Renderer facts (drive Phase 0.4 substrate)

- Renderer already runs on **OpenGL ES 3.0** as-is; GLSL is **generated in C at runtime** (`shader.c`), emitting `#version 300 es` (or `310 es` for the MD5/SSBO path). Only the shader backend is used on iOS; the legacy/ARBfp backend is desktop-only.
- ES-3.0-clean: dynamic lights (UBO), bloom (MRT + RGBA8 FBOs), underwater warp, fog, sky (cubemap/classic), particles, MD2/MD3 GPU vertex-lerp, VAO+streamed VBO/EBO submission, fence sync, mipmaps, anisotropy.
- **The one gap:** MD5 rerelease hi-detail **animated** models need GPU skeletal skinning via **SSBO (ES 3.1)** or **buffer texture (ES 3.2)**; native ES 3.0 has neither and there is **no CPU-skinning fallback** wired (`models.c:1694-1714` forces `use_gpu_lerp`, then disables `gl_md5_load`). ANGLE (ES 3.1) supplies SSBO → MD5 lights up with zero renderer changes. This is the crux of the substrate decision (D3).
- The macOS oracle runs desktop **GL 3.2 core** (macOS caps at 4.1 → no SSBO); it gets MD5 via the **buffer-texture** path.

## Source-of-truth files

Loop `common.c:1067`, `client/main.c:3273`, `unix/system.c:560` · Present
`refresh/main.c:919-944` · Video vtable `inc/client/video.h` · SDL backend
`src/unix/video/sdl.c` · Renderer entry `refresh/main.c:803` · Caps/gating
`refresh/qgl.c`, `refresh/models.c:1683` · Shaders `refresh/shader.c` · Demo/timedemo
`client/demo.c` · Game load `common/gamedll.c` · View/weapon feel
`subprojects/rerelease-game/rerelease/p_view.cpp`, `p_weapon.cpp`.
