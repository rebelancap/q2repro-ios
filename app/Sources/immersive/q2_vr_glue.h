// q2_vr_glue.h — the ABI between the Swift/Metal VR compositor and the engine-side glue.
// Kept engine-header-free so the Swift bridging header can import it.
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <simd/simd.h>

// Frame ownership. Exactly one of these owns Qcommon_Frame at any instant, and the owner is
// asserted in the black box on every transition.
enum { Q2VR_OWNER_LINK = 0, Q2VR_OWNER_VR = 1 };

// One eye's contribution to a published pair. Offsets are in HEAD-LOCAL axes and METRES;
// tangents are positive magnitudes of the frustum edges at unit distance, in the
// compositor's own convention (x right, y up, z back).
// [R10 item 2] `znear_m` is PER EYE. It used to be taken from eye 0's projection alone
// (`pose.znear_m`) and used to convert BOTH eyes' depth and to set BOTH eyes' engine near
// plane. That is correct only while the two views report the same near plane; if they ever
// differ, eye 1's written depth decodes against the wrong constant and eye 1 reprojects
// wrong. One field, filled from each view's own projection, removes the assumption.
// 0 means "not filled" and the pose-level `znear_m` is used, so nothing regresses.
typedef struct {
    float ofsFwd, ofsRight, ofsUp;
    float tanL, tanR, tanU, tanD;
    float znear_m;              // this view's own near plane, metres (0 = use pose.znear_m)
} q2_vr_eye_t;

// --- [R14] the depth constants that ride a published pair (xr3_glue.m) ---------------
// THE CONSTANTS THE COMPOSITE MUST DECODE *THIS* PAIR'S DEPTH WITH, captured on the engine
// thread in EndFrame and published inside the same seqlock as the five textures. They are
// engine state, they change under the compositor (zfar on every map load, worldScale from a
// cvar), and the pair being presented is one to three frames older than the engine's "now".
typedef struct {
    float znear;        // engine near plane, WORLD UNITS, as this pair was rendered
    float zfar;         // engine far plane, WORLD UNITS (q2vr.zfar_used; per MAP)
    float worldScale;   // world units per metre at render time
    float nearC[2];     // per-eye compositor near plane, METRES (0 = not filled)
} q2_vr_depthconst_t;

// One hand, already in the game's frame (R4). It rides INSIDE the published pose for the
// same reason both eyes do: the head and the hands must be a matched set. A hand sampled in
// a different breath from the head is a hand whose aim disagrees with the camera it is drawn
// against by exactly the amount the player moved in between, and that disagreement is only
// ever visible while they move — which is the hardest class of bug this campaign has already
// paid for once.
//
// Angles are Quake convention (pitch positive DOWN), yaw relative to the yaw-only base, and
// they come from the SAME function the head's angles come from, so there is exactly one named
// aim frame in the port. Offsets are HEAD-LOCAL axes in METRES from the play-space origin —
// deliberately the identical form as `headFwd/headRight/headUp`, so the engine composes a
// hand with the eye's own arithmetic and hands, eyes and weapon land in one frame by
// construction rather than by two derivations agreeing.
typedef struct {
    int      present;           // a controller is assigned to this hand
    int      posed;             // it had a tracked pose (or an injection) this frame
    int      held;              // the anchor says it is in a hand, not on a table
    float    yawDeg, pitchDeg, rollDeg;
    float    ofsFwd, ofsRight, ofsUp;
    unsigned buttons;           // Q2_SENSE_* level, for the dumps
    float    trigger, grip;
    float    stickX, stickY;
} q2_vr_hand_t;

// What the compositor publishes and the engine renders with. The head pose and BOTH eyes
// live in one struct on purpose: the eyes must be a matched set, and a struct that can only
// be read whole is a design that cannot be half-copied.
typedef struct {
    uint64_t    id;             // monotonic; assigned by Q2_VR_Publish
    int         valid;          // 0 until a device anchor has been seen
    int         views;          // 1 in the simulator, 2 on the device
    float       headFwd, headRight, headUp;    // head translation from the play-space origin
    float       headYawDeg, headPitchDeg, headRollDeg;   // Quake-convention degrees
    float       znear_m;        // the compositor's own near plane, metres
    q2_vr_eye_t eye[2];
    q2_vr_hand_t hand[2];       // [vr R4] 0 = left, 1 = right; same frame id as the head
} q2_vr_pose_t;

#ifdef __cplusplus
extern "C" {
#endif

// --- rendezvous -----------------------------------------------------------------------
uint64_t Q2_VR_Publish(const q2_vr_pose_t *p);   // compositor: publish, get an id
bool     Q2_VR_WaitRendered(uint64_t id);        // compositor: <=14 ms; false = re-present
bool     Q2_VR_EngineAcquire(q2_vr_pose_t *out); // engine: <=20 ms; false = stale pair
void     Q2_VR_EngineRelease(uint64_t id);
void     Q2_VR_SetRendezvousActive(int on);      // deactivation broadcasts unconditionally

// --- frame ownership ------------------------------------------------------------------
int  Q2_VR_StartEngineThread(void);
void Q2_VR_RequestEngineStop(void);              // a request plus a poll, never a join
void Q2_VR_FinishEngineStop(void);
int  Q2_VR_EngineThreadRunning(void);
int  Q2_VR_FrameOwner(void);

// --- two-phase entry ------------------------------------------------------------------
void Q2_VR_ReportPhysicalSize(int w, int h);     // the view's PHYSICAL colour texture
void Q2_VR_ForcePhysicalSize(int w, int h);      // harness: latch a shape (0 0 releases)

// --- arbitration + diagnostics --------------------------------------------------------
int         Q2_VR_PresentIsWorld(void);
const char *Q2_VR_PresentReason(void);
float       Q2_VR_WorldScale(void);
float       Q2_VR_DepthFloor(void);
// [R17] the compositor A/B switches (q2_vr_dumps.m; console q2vrfreerun/q2vrdepth/
// q2vranchor/q2vrdiv/q2vrfreeze/q2vrmono). Read every frame; never need a VR re-entry.
int         Q2_VR_FreeRun(void);
int         Q2_VR_DepthMode(void);
int         Q2_VR_AnchorMode(void);
int         Q2_VR_PoseDivisor(void);
// [R21] The RAW `q2vrdiv` override: 0 = auto (nobody pinned one), N = pinned. Where
// `Q2_VR_PoseDivisor` has folded R17's auto rule in and so cannot tell "auto on a 120 Hz
// layer" from "pinned to 2", this can — which is what lets the adaptive controller know
// whether it is allowed to move the divisor at all.
int         Q2_VR_PoseDivisorRaw(void);
int         Q2_VR_Freeze(void);
int         Q2_VR_Mono(void);
void        Q2_VR_NoteLayerPeriod(double seconds);
int         Q2_VR_LayerPeriodUs(void);
// [R21] THE PACING CONTROLLER (q2_vr_glue.m). The engine follows the LAYER's rate — the sim
// cadence (`cl_maxfps`) is set from the measured layer rate and restored on VR exit, and the
// pose divisor is measured rather than assumed. `Q2_VR_EffectivePoseDivisor` is what
// `Q2_VR_EngineAcquire` uses; `Q2_VR_PoseDivisor` remains the A/B override's own answer.
int         Q2_VR_EffectivePoseDivisor(void);
// The GPU instrument. `Q2_VR_NoteEngineGpu` is fed by xr3_glue's disjoint-timer query (the
// engine's own GPU work for a whole host frame, both eyes plus the UI pass);
// `Q2_VR_NoteCompositorGpu` is fed by the compositor's command-buffer
// `gpuEndTime - gpuStartTime` in VRShell.swift. Both are milliseconds, both are safe to call
// from any thread, and both are ignored outside (0, 1000). The fields ride PACENOW and the
// once-a-second VRGPU line.
void        Q2_VR_NoteEngineGpu(double ms);
void        Q2_VR_NoteCompositorGpu(double ms);
// [R21 review] app-delegate background state; the pacing activation repair is refused while set.
void        Q2_VR_SetAppBackgrounded(int on);
int         Q2_VR_AppBackgrounded(void);
// [R23] THE ENTRY WATCH. The black-screen-with-audio entry is intermittent per entry,
// which by D-VR-R16 is a race — so the entry counts the five things that must line up for a
// VR entry to show a picture and prints ONE `VRENTRY` line naming the state it is in
// (`ok`, `no_comp`, `no_pair`, `not_adopted`, `no_anchor`, `mainticks`). The compositor
// feeds it per frame; the engine thread prints it, at 2 s, and again at 6 s if the first
// verdict was not `ok` or a heal has fired. `q2vrbb` echoes the pinned copy.
void        Q2_VR_ArmEntryWatch(int on);          // per SESSION, with the rendezvous
void        Q2_VR_NoteCompositorFrame(int adopted, int anchored, int shellGen, int pipelineOk);
void        Q2_VR_NoteArkit(int state, int errorBump);   // provider state ordinal; run threw
void        Q2_VR_NoteEntryHeal(const char *what);       // the self-heal fired
int         Q2_VR_EntryHealCount(void);
void        Q2_VR_NoteCurtain(int up);                   // the 2D window's curtain, as an outcome
void        Q2_VR_EntryWatch(void);                      // engine thread, end of frame
void        Q2_VR_SetEntryFault(int mask);               // dev: 1 = no anchor, 2 = no pair
int         Q2_VR_EntryFault(void);
void        Q2_VR_NoteGpuTimerUnavailable(void);
void        Q2_VR_DumpGpuFields(char *out, int outsz);
int         Q2_VR_BlackBoxPinGet(const char *key, char *out, int outsz);
void        Q2_VR_DumpContract(const char *structural, const char *volatileLine);
void        Q2_VR_Log(const char *msg);

// --- alignment chain (q2_vr_input.m) --------------------------------------------------
// Recentre is deliberately split across the two sides: the compositor owns the yaw-only
// BASE because that is where the anchor lives, and the input module owns the BODY YAW that
// absorbs the yaw the base just discarded. One call site each, so the halves cannot drift.
void  Q2_VR_RequestRecenter(void);
int   Q2_VR_ConsumeRecenterRequest(void);
void  Q2_VR_NoteRecenter(float headYawDeg);
void  Q2_VR_NoteHeadHeight(float metres);      // sampled per frame, captured ONCE, gated
float Q2_VR_UIDistance(void);                  // metres to the head-locked UI quad

// --- the VR settings section (charter D11, stored by XR3SettingsSheet) -----------------
// Read by the compositor every frame. Everything here is a ROW: the sheet stores, the engine
// applies on a bumped generation, and these are the two values the Metal side needs directly.
float Q2_VR_Sharpen(void);                     // CAS strength on the eye composite, 0..1
float Q2_VR_UIHeightOffset(void);              // metres, the HUD quad's vertical anchor
// The HUD Size row is carried by TWO mechanisms (q2_vr_input.m has the split in full): the
// engine re-lays the HUD out up to a layout cap, and the compositor magnifies the quad's
// angular extent for whatever the row asked for beyond it. 1.0 means "the layout took all
// of it"; ~1.90 is the top of the row.
// R23 — and it now carries HUD SPREAD as well: Spread multiplies the quad and divides the
// engine's layout multiplier by the same factor, so every element keeps its angular size
// while the canvas they are anchored to grows. The product Q2_VR_HudSize x Q2_VR_HudMagnify
// is therefore invariant in Spread and equal to row x 3.5 at every setting of both rows.
float Q2_VR_HudMagnify(void);                  // HUD quad extent scale, >= 1.0
float Q2_VR_HudSpread(void);                   // HUD canvas spread, 1.0 .. 2.0
int   Q2_VR_UIVisible(void);                   // 0 = HUD Position "Off" (menus unaffected)
// R13 — THE WHEEL, and the two things the COMPOSITOR needs to know about it.
// `Q2_VR_WheelOpenMirror` is an atomic mirror of the client's CL_iOS_WheelOpen, written once
// per world frame on the engine thread and read on the compositor thread — and the reason
// UIVisible above can now be true with HUD Position "Off" (a
// wheel the player opened must never be invisible because they turned the health bar off).
// `Q2_VR_WheelPull` is the DEPTH answer for a 2D wheel: quadModel derives the quad's
// half-width from its distance, so easing the whole UI quad closer while a wheel is open
// changes the vergence and the reprojection depth and leaves the angular size pixel-identical.
int   Q2_VR_WheelOpenMirror(void);             // 0 closed, 1 weapon wheel, 2 powerup wheel
void  Q2_VR_NoteWheelOpen(int open);           // engine thread, once per world frame
float Q2_VR_WheelPull(void);                   // q2vrwheelpull, 0.25..1.0 (1.0 = off)
void  Q2_VR_ApplySettings(int force);
// [R22] R10's VR STATS OVERLAY IS GONE. The row (vr_stats) was retired in R21 — the numbers
// it drew are all in the VRGPU/PACENOW lines the console and the black box already carry —
// and R22 removed the last of its plumbing: Q2_VR_StatsOn / Q2_VR_SetStatsText /
// Q2_VR_StatsCopy no longer exist and `q2vr.stats_text` is left NULL, so overlay 0035's
// draw is dead code that never fires.
float Q2_VR_RSSMB(void);                       // this app's physical footprint, MB
// R11 — WHICH EYE HOSTS THE 2D REDIRECT (`vr_ui_eye`, console-only, default 0).
//   0 = eye 0 draws the 2D stream (the shipped arrangement)
//   1 = eye 1 draws it
//   2 = neither: a pass of its own after both eyes, with no eye framebuffer bound
//       (overlay 0036's `q2vr.ui_only` + VID_iOS_XR3_BeginUIPass below)
// The instrument behind the left-eye jitter: today's arrangement INTERRUPTS eye 0's render
// pass and no other, which is the last structural left/right asymmetry the simulator cannot
// exercise. Mode 1 is the A/B; mode 2 is the shape a fix would take.
int   Q2_VR_UIEye(void);
void  Q2_VR_ClearHeightBaseline(void);

// --- hands (q2_vr_hands.m, R4) ---------------------------------------------------------
// Called by the compositor in the SAME breath as the head anchor query and BEFORE
// Q2_VR_Publish, so the hands ride the head's frame id. `base` is the yaw-only alignment
// base (`baseFromWorld`); when it has not been captured yet, pass valid = 0 and the hands
// come back present-but-not-posed, which is honest rather than wrong.
void  Q2_VR_HandsCompose(simd_float4x4 base, int baseValid, q2_vr_hand_t out[2]);
// Read by the engine and the dumps.
int   Q2_VR_AimHand(void);
int   Q2_VR_CrosshairOn(void);
float Q2_VR_CrosshairSize(void);   // R9 — the Crosshair Size row, 0.5x ... 3.0x
float Q2_VR_WeaponSize(void);
int   Q2_VR_HapticsOn(void);
int   Q2_VR_HandsDrivesWorld(void);   // 1 while VR gameplay owns the Sense pair

// --- the VR 2D panel shape (xr3_glue.m, R3) -------------------------------------------
// The 16:9 sub-rect of the eye texture the engine composes non-world 2D into, or 0x0 when
// the eye shape is in force. The compositor asks rather than assumes: the quad's aspect and
// its texture coordinates must both come from the rect the engine actually used.
void  VID_iOS_XR3_SetPanelShape(int on);
void  VID_iOS_XR3_PanelRect(int *w, int *h);

// --- the 2D-redirect UI surface (xr3_glue.m) ------------------------------------------
void  VID_iOS_XR3_SetUIRedirect(int on);
int   VID_iOS_XR3_UIReady(void);
void *VID_iOS_XR3_UITexture(void);             // published RGBA8 MTLTexture, or NULL
// [R7a item 2] The whole published set as ONE consistent snapshot (a seqlock read). The VR
// composite takes colour, depth and UI through this so a publish cannot land between two of
// its reads and pair frame N's colour with frame N+1's depth.
// [R8] `poseId` is the rendezvous id the pair was RENDERED with — it rides the same seqlock
// as the textures, so the compositor can submit the head anchor those pixels belong to
// rather than the anchor of the frame it is assembling now. 0 = nothing published yet.
// [R9] `serial` is a monotonic publish counter and `slot` the ring slot the pair lives in,
// both read inside the same seq check. The consumer RETAINS the slot for the life of the
// command buffer that samples it (VID_iOS_XR3_SlotRetain/Release) so the engine cannot start
// overwriting those textures underneath the read; `serial` is the correct "is this a new
// pair?" gate for per-publish work such as the sharpen pass. slot = -1 means "no slot".
// [R14] `depthConst` is the DEPTH-DECODE CONSTANT SET the pair was rendered with, and
// `fenceEvent`/`fenceValue` are the Metal shared event ANGLE signals for that pair. Both ride
// the same seq check as the textures, for the two reasons R14 exists:
//   - the composite used to read `q2vr.znear` / `q2vr.zfar_used` LIVE off the engine thread
//     while decoding a pair that may be several frames old. `zfar_used` is
//     `gl_static.world.size * 2` and changes on every map load, so any pair presented across
//     a load had its whole depth buffer decoded against the wrong constant — the world
//     reprojects at the wrong distance for a frame or two, which is exactly the "duplicate of
//     the world in a flash, worst right after a level loads" report.
//   - the compositor's Metal queue has NO ordering with ANGLE's. The publish is armed from a
//     CPU shared-event listener; waiting on the same event/value inside the presenting command
//     buffer states the dependency to the GPU instead of inferring it from the CPU.
// Any of the three may be NULL. `depthConst->zfar <= 0` means "no pair has been published
// yet" and the caller must fall back to its live reads.
void  VID_iOS_XR3_AcquirePublished(void **c0, void **c1, void **d0, void **d1, void **ui,
                                   uint64_t *poseId, unsigned *serial, int *slot,
                                   q2_vr_depthconst_t *depthConst,
                                   void **fenceEvent, uint64_t *fenceValue);
void  VID_iOS_XR3_SlotRetain(int slot);
void  VID_iOS_XR3_SlotRelease(int slot);
// frames = BeginEye(0) calls this session, waits = those that found a reader on their slot,
// heals = those that gave up waiting (a wedged consumer; must stay 0).
void  VID_iOS_XR3_SlotStats(int *frames, int *waits, int *heals);
// Engine thread, immediately before VID_iOS_XR3_EndFrame: the id this frame rendered with.
void  VID_iOS_XR3_SetFramePoseId(uint64_t id);
uint64_t VID_iOS_XR3_PublishedPoseId(void);
void  VID_iOS_XR3_UISize(int *w, int *h);
// R11 — bind the UI framebuffer as the pass's OWN target (`vr_ui_eye 2`). Unlike UIBegin it
// leaves no eye framebuffer to return to: it points `s_currentEyeFbo` at the UI surface, so
// the bracket's UIEnd is a rebind of the same target and nothing re-opens an eye's pass after
// its pixels were published. Engine thread, between the eye-1 render and EndFrame.
void  VID_iOS_XR3_BeginUIPass(void);
// R11 — PER-EYE DEPTH READBACK of the currently published pair, the same seqlock+slot-retain
// path q2vrshot's pair capture uses. Writes two 16-bit PGMs and fills `line` with the
// VRDEPTH summary (per-eye min/max/mean and the saturated fractions, plus the mean |d0-d1|
// over the frame). Returns 0 on success.
int   Q2_VR_DepthShotPair(const char *path0, const char *path1, char *line, int linesz);
// R5 / Q-VR9: the sub-rect of the UI texture the HUD was last composed into (0x0 = the whole
// texture, i.e. the old square layout). Same contract as the panel rect above, and for the
// same reason — one number decides both the quad's shape and its texture coordinates.
// --- VR pacing counters (q2_vr_glue.m, R5) --------------------------------------------
// Counted at the two ends of the rendezvous; `q2vrpace` dumps them, `q2vrpace reset` zeroes
// them, and entering VR zeroes them too so a session's numbers need no setup step.
void  Q2_VR_PaceReset(void);
void  Q2_VR_DumpPaceFields(char *out, int outsz);

// --- the pose residual (q2_vr_glue.m, R7a item 2) --------------------------------------
// The positional twin of `q2vryawtrace`: the metres between the view origin the ENGINE
// wrote and the one the SHELL's published pose says it should have written. Zero on a
// correct frame; the camera's error on a wrong one. Zeroed by Q2_VR_PaceReset, so entering
// VR resets it with everything else.
void  Q2_VR_PoseResidualReset(void);
void  Q2_VR_DumpResidualFields(char *out, int outsz);
void  Q2_VR_DumpResidualRing(void (*emit)(const char *));

void  VID_iOS_XR3_UIRect(int *w, int *h);
void  VID_iOS_XR3_SetHudWide(int on);
int   VID_iOS_XR3_HudWide(void);


// --- [R14] the publish fence (xr3_glue.m) ---------------------------------------------
// THE PUBLISH FENCE MODE (`q2vrpubfence`, default 3). The A/B behind the R14 flicker
// diagnosis, live-settable from the console so one headset session can decide it:
//   0  today's behaviour: no wait of any kind
//   1  glFlush + eglWaitUntilWorkScheduledANGLE before the sync is created
//   2  glFinish before the sync (diagnostic; costs the producer its pipelining)
//   3  the GPU-side wait: the presenting command buffer encodes a waitForEvent on the same
//      shared event/value ANGLE signals for the pair it is about to sample
// `mean`/`max` are the CPU microseconds spent inside the pre-sync step (0 in modes 0 and 3),
// over the window since the last read; reading them RESETS the window.
void  VID_iOS_XR3_SetPubFence(int mode);
int   VID_iOS_XR3_PubFence(void);
void  VID_iOS_XR3_PubFenceStats(double *meanUs, double *maxUs);

// --- depth handoff (xr3_glue.m) -------------------------------------------------------
void  VID_iOS_XR3_SetVRDepth(int on);            // per-eye depth textures instead of the RB
int   VID_iOS_XR3_VRDepthActive(void);
void *VID_iOS_XR3_DepthTexture(int eye);         // published Depth32Float MTLTexture, or NULL
void  VID_iOS_XR3_DepthParams(float *znear, float *zfar);   // world units, as rendered
void  VID_iOS_XR3_SetVREyeSize(int w, int h);    // engine thread only

// [R20] MSAA EYE RENDERING. `Q2_VR_MsaaWanted` is the settings side (the VR Anti-aliasing
// row / `q2vrset vr_msaa`, cached on the settings generation); the three XR3 accessors are
// what the eye path actually ended up with, and they are what the VRSIZE/EYENOW lines report.
// Active can be 0 while wanted is 4: the context may cap GL_MAX_SAMPLES, or a refused
// allocation or resolve may have disabled MSAA for the session (always with a console line).
int   Q2_VR_MsaaWanted(void);                    // 0, 2 or 4 — what the player asked for
int   VID_iOS_XR3_MsaaActive(void);              // samples the eye FBO is really rendering at
int   VID_iOS_XR3_MsaaBackendSamples(void);      // [R22] what ANGLE actually allocated, 0 = none yet
int   VID_iOS_XR3_MsaaMax(void);                 // GL_MAX_SAMPLES as ANGLE reports it
int   VID_iOS_XR3_MsaaImplicit(void);            // GL_EXT_multisampled_render_to_texture seen

#ifdef __cplusplus
}
#endif
