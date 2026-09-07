// q2_vr_glue.m — the VR substrate: pose rendezvous, engine thread, frame ownership,
// present-mode arbitration, and the pose composition the engine's VR gate consumes.
//
// WHY THIS FILE IS SEPARATE FROM THE COMPOSITOR. The compositor loop is Swift + Metal +
// CompositorServices; this file is C compiled against the engine's headers. Both donors
// converged on that split for the same reason q2repro needs it: engine headers and the
// system frameworks cannot live in one translation unit without collisions, and the engine
// side then registers everything through Cmd_AddCommand after Com_Init instead of needing
// an engine patch. xr3_glue.m is already that pattern; this is its VR sibling.
//
// WHY A DEDICATED ENGINE THREAD, AND WHY BEFORE THE SPACE OPENS. Under a `.full` immersive
// space visionOS stops ticking the hidden 2D window's display link. A port whose engine is
// driven by that link freezes on the entry frame — the 2D window stops, VR shows one frame
// forever, and audio keeps playing because the mixer is no longer pumped. The donors lost a
// device round to exactly this. So frame ownership moves to a thread of our own BEFORE the
// space opens, with no dependence on window-scene lifecycle, and the display link is paused.
//
// WHY A RENDEZVOUS AND NOT FREE-RUN. The 3D panel can free-run: the compositor samples
// whatever the engine last drew and puts it on a world-locked quad, and a frame late is a
// frame late. VR cannot. If the pose the engine RENDERED with is not the pose the
// compositor REPROJECTS against, the world shakes with every head sway. One mutex, one
// condvar, one monotonic frame id; the engine renders exactly the published pair.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdlib.h>            // qsort, for the R21 percentile rings
#include <string.h>
#include <math.h>
#include <mach/mach.h>
#include <mach/task_info.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"
#include "client/video.h"
#include "system/system.h"      // Sys_Milliseconds, for the residual ring's timestamps

#include "q2_vr_glue.h"

// ---- engine entry points (declared, not included — see the file header) ---------------
extern void Qcommon_Frame(void);
// [overlay 0046] The client's frame-throttle state — sync mode name, cls.active,
// cls.state, and the three msec budgets. Every one of them is private to src/client, and
// all five together are what decides how often the sim actually steps (see THE PACING
// CONTROLLER). Any out pointer may be NULL; the returned name is never NULL.
extern const char *CL_SyncModeProbe(int *active, int *state, int *main_ms, int *phys_ms, int *ref_ms);
// [R21] The client's activation seam (client/main.c). `CL_Activate` is a no-op when the state
// already matches; when it does not it re-runs IN_Activate, S_Activate (the audio session and
// unit) and CL_UpdateFrameTimes. The 2D shell drives it from the scene phase (main.m
// Q2_XR3_ScenePhase); VR drives it only for the one case below, and only on a transition.
extern void CL_Activate(int active);
#define Q2VR_ACT_ACTIVATED 2   // active_t: ACT_MINIMIZED, ACT_RESTORED, ACT_ACTIVATED
extern void SCR_UpdateScreen(void);
extern bool V_FrameRendered(bool clear);            // overlay 0018
extern void V_SuppressFrameRender(bool suppress);   // overlay 0030
extern void R_SetRepeatFrame(bool repeat);          // overlay 0031
extern void VID_iOS_XR3_BeginEye(int eye, float halfSep, float convergence);
extern void VID_iOS_XR3_EndFrame(void);
extern void VID_iOS_XR3_SetFramePoseId(uint64_t id);
extern int  VID_iOS_XR3_Active(void);
extern void VID_iOS_XR3_SetVRDepth(int on);
extern void VID_iOS_XR3_SetVREyeSize(int w, int h);
extern void VID_iOS_XR3_DepthParams(float *znear, float *zfar);
extern int  VID_iOS_XR3_VRDepthActive(void);
extern int  VID_iOS_XR3_PubEpoch(void);
extern int  VID_iOS_XR3_PubRefused(void);
// [R23] the entry watch's counters (see THE ENTRY WATCH below)
extern int  VID_iOS_XR3_FramesRendered(void);
extern int  VID_iOS_XR3_InFlight(void);
extern int  VID_iOS_XR3_EyeGeneration(void);
extern unsigned Q2_VR_MainTicksInVR(void);
extern void VID_iOS_XR3_EyeSize(int *w, int *h);
extern void Q2_iOS_QueueDrain(void);
extern void Q2_iOS_FunnelEnable(int on, void *ownerThread);
extern void Q2_VR_Tick(void);
extern void Q2_VR_BlackBoxPin(const char *key, const char *line);
// [R19] the memory breadcrumbs (q2_vr_dumps.m) and the ring the budget below spends
extern void Q2_VR_MemStats(float *cur_mb, float *peak_mb, float *avail_mb);
extern int  Q2_VR_MemLine(char *out, int size);
extern int  VID_iOS_XR3_RingDepth(void);
extern void Q2_VR_BlackBoxLog(const char *line);
extern void Q2_VR_BlackBoxFlush(int force);
extern void Q2_VR_Log(const char *msg);
extern void Q2_VR_NotePresent(void);
extern void Q2_VR_SetPoseValid(int v);
extern void Q2_VR_SetDrawableReady(int v);
extern int  Q2_VR_PresentIsWorld(void);
extern const char *Q2_VR_PresentReason(void);
extern float Q2_VR_WorldScale(void);
extern float Q2_VR_DepthFloor(void);
extern int   Q2_VR_PoseOverride(float *yaw, float *pitch, float *fwd, float *right, float *up);
extern void Q2_iOS_AudioTick(void);
extern bool VID_iOS_ANGLE_AcquireContext(void);
extern void VID_iOS_ANGLE_ReleaseContext(void);
extern void Q2_VR_InputFrame(float headYaw, float headPitch, int world, int poseValid);
extern float Q2_VR_BodyYaw(void);
extern void Q2_VR_ApplySettings(int force);
extern void VID_iOS_XR3_SetPanelShape(int on);
extern void VID_iOS_XR3_PanelRect(int *w, int *h);
extern float Q2_VR_UIHeightOffset(void);
extern void Q2_VR_NoteHeadHeight(float metres);
extern void VID_iOS_XR3_UIBegin(void);
extern void VID_iOS_XR3_UIEnd(void);
extern int  VID_iOS_XR3_UIReady(void);
extern void VID_iOS_XR3_SetUIRedirect(int on);

// =====================================================================================
// The rendezvous
// =====================================================================================
// Relative waits, deliberately. Apple's pthreads have no pthread_condattr_setclock, so a
// port that reaches for CLOCK_MONOTONIC here does not compile; pthread_cond_timedwait_relative_np
// is the platform's own answer and it is not affected by wall-clock steps.
//
// Nothing on this path is smoothed, damped or filtered. Damping belongs in the base
// placement, never in the pose a frame is reprojected against.

#define Q2VR_ENGINE_WAIT_MS 20      // engine: timeout -> re-render the PREVIOUS pair
#define Q2VR_SHELL_WAIT_MS  14      // shell: timeout -> re-present the previous pair

static pthread_mutex_t  vr_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t   vr_cv  = PTHREAD_COND_INITIALIZER;
static q2_vr_pose_t     vr_published;      // guarded by vr_mtx
static uint64_t         vr_pub_id;         // monotonic, guarded by vr_mtx
static uint64_t         vr_rendered_id;    // last id the engine released, guarded by vr_mtx
static bool             vr_rendezvous_on;  // guarded by vr_mtx

// ---- pacing counters (R5) --------------------------------------------------------------
// VR pacing has four consumers now (the world traversal, the UI pass, CAS, the Sense poll)
// and has never been measured on the device. The rule from the charter is that a device
// session must yield MEASUREMENTS rows with ZERO extra steps, so every number a pacing row
// needs is counted here, at the two ends of the rendezvous, and dumped by one command.
//
// Counted, not sampled: a sampled rate cannot tell a steady 90 Hz from a 120 Hz that drops
// every fourth frame, and the drop is the thing worth knowing. The worst gap is kept
// separately for the same reason — an average hides exactly the hitch a player feels.
//
// All plain relaxed atomics: these are diagnostics on a hot path, and a counter that costs
// a barrier on every compositor frame would be measuring itself.

// The app's PHYSICAL FOOTPRINT, which is the number visionOS actually kills a process over —
// not resident_size, which under-reports Metal texture residency (the exact thing R9's ring
// and quality changes moved). Same source Xcode's memory gauge reads.
float Q2_VR_RSSMB(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return 0.0f;
    return (float)((double)info.phys_footprint / (1024.0 * 1024.0));
}

static atomic_ullong pace_pub, pace_repres, pace_stale, pace_engine;
static atomic_ullong pace_first_ns, pace_last_ns, pace_worst_gap_ns;
// [R7a item 1] How many frames went to the PANEL rather than the world. It is the
// denominator the left-eye flicker lived in, and it separates "the menu is up" from "the
// engine is stalled" in one number. There is deliberately no companion "miss" counter: the
// panel branch now draws both eyes unconditionally, so there is no miss left to count, and
// the first version of this pair shipped a count that was 100 % by construction — see the
// comment on the branch itself.
static atomic_ullong pace_panel;

static uint64_t vr_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

// =====================================================================================
// [R7a item 2] THE POSE RESIDUAL — the instrument that answers "did the jitter fix take?"
// =====================================================================================
// R3 shipped `q2vryawtrace`, which proves the rendered YAW equals body + head + server.
// That residual was already zero and stayed zero while the world kept shaking, because the
// jitter was never in the yaw: it was in the POSITION. The head's play-space displacement
// rode inside `eyeofs` and was rotated by the finished view angles, so turning the head
// swung the camera around the play origin — see shared.h.
//
// This is the positional twin, and it is a genuine CROSS-CHECK rather than a restatement of
// the fix: the expected view origin is recomposed HERE, from the shell's own published pose
// (`vr_frame`), and compared against the origin the ENGINE actually wrote (`q2vr.vieworg`
// minus `q2vr.baseorg`). Two independent derivations from two translation units. It is zero
// on a correct frame, it is the camera's error in METRES on a wrong one, and — this is the
// point — it is non-zero for a STALE pose or a mismatched anchor just as surely as for a
// wrong basis, so it does not go blind the moment this round's particular bug is fixed.
//
// Always on in VR, sampled every world frame, summarised into the black box once a second
// with a ring of the worst offenders. The next casual session produces the verdict with
// no console work: `residworstm` at 0.000 over a session with head movement is the answer.
#define VR_RESID_RING 8
static double   resid_sum_m;
static float    resid_worst_m;
static unsigned resid_n;
static struct { float m, headyaw, dist_m; unsigned ms; } resid_ring[VR_RESID_RING];
static int      resid_ri, resid_rn;

void Q2_VR_PoseResidualReset(void)
{
    resid_sum_m = 0.0; resid_worst_m = 0.0f; resid_n = 0;
    resid_ri = 0; resid_rn = 0;
    memset(resid_ring, 0, sizeof resid_ring);
}

void Q2_VR_DumpResidualFields(char *out, int outsz)
{
    Q_snprintf(out, outsz,
               "RESIDNOW samples=%u meanm=%.4f worstm=%.4f ringrows=%d",
               resid_n, resid_n ? resid_sum_m / resid_n : 0.0, resid_worst_m, resid_rn);
}

void Q2_VR_DumpResidualRing(void (*emit)(const char *))
{
    char line[160];
    // Not a chronological ring: the slots hold the worst frames seen, so they are enumerated
    // in slot order and each row carries its own timestamp.
    for (int i = 0; i < resid_rn; i++) {
        Q_snprintf(line, sizeof line, "RESIDROW %u errm=%.4f headyaw=%.1f headdistm=%.3f",
                   resid_ring[i].ms, resid_ring[i].m, resid_ring[i].headyaw,
                   resid_ring[i].dist_m);
        emit(line);
    }
}

static void vr_pace_controller_reset(void);   // [R21] defined with the pacing controller below

void Q2_VR_PaceReset(void)
{
    atomic_store(&pace_pub, 0); atomic_store(&pace_repres, 0);
    atomic_store(&pace_stale, 0); atomic_store(&pace_engine, 0);
    atomic_store(&pace_worst_gap_ns, 0);
    atomic_store(&pace_first_ns, 0); atomic_store(&pace_last_ns, 0);
    atomic_store(&pace_panel, 0);
    Q2_VR_PoseResidualReset();
    vr_pace_controller_reset();
}

// =====================================================================================
// [R21] THE PACING CONTROLLER — the engine follows the LAYER, and the layer is not 60 Hz
// =====================================================================================
// Reported in the headset on 1.0.11.24: "why is 60 our max? The M5 Vision Pro can hit 120 Hz
// but 90 is more common (it depends on lighting) — can we lock the FPS to whatever refresh
// rate the Vision Pro is at? It varies even in a game."
//
// It varies, and NOTHING here may assume a rate. Three separate rates were being confused:
//
//  1. THE LAYER RATE. CompositorServices tells us the period of the frame it is asking for;
//     `Q2_VR_NoteLayerPeriod` records it every compositor frame and VRCLOCK reports it as
//     `perhz`. It has been measured at 120.0 and at 60.0 on the SAME headset in different
//     sessions, so it is a live input, never a constant.
//  2. THE ENGINE RATE. Under R17's free-running compositor the engine renders one eye pair
//     per Nth published pose (the divisor), so its ceiling is layer/N and its floor is
//     whatever a frame costs.
//  3. THE SIM RATE. `cl_maxfps` (upstream default **62**, no flags — see
//     `src/client/main.c` ~2775) governs `CL_Frame`'s physics/command step, and with
//     `cl_async 0` it governs the WHOLE frame: `SYNC_MAXFPS` returns from `CL_Frame`
//     before prediction, before `CL_UpdateCmd`, before everything, whenever the
//     accumulated time is under `main_msec`. At a 90 or 120 Hz layer that is a sim
//     stepping 62 times a second under a renderer drawing 90 or 120 pairs a second: the
//     duplicated view positions that read as "choppy".
//
// SO: the sim cadence is set FROM the measured layer rate, every time the layer rate moves,
// and put back on exit. `cl_maxfps`, `cl_async` and `r_maxfps` are all `Cvar_Get(..., 0)` —
// NO `CVAR_ARCHIVE` — so unlike the R12 override set they can never reach the player's
// config.cfg, and an in-process save/restore is the whole obligation. (That is why they are
// not in `vr_overrides`: the NSUserDefaults stash exists for cvars a crash could persist.)
//
// WHY `cl_async 1` AND NOT 0. With async the render is decoupled: `phys_msec` comes from
// `cl_maxfps` and `ref_msec` from `r_maxfps` (0 = the 1000 Hz cap, i.e. never a throttle),
// and the frame runs prediction, `CL_UpdateCmd` and `S_Update` on EVERY host frame rather
// than early-returning. Overlay 0030 already suppresses `CL_Frame`'s inner render, so async
// costs us nothing and buys the property we need: no host frame is ever a no-op.
//
// UPSTREAM'S CLAMP IS THE CEILING: `MAX_PHYS_HZ` is 125, and `cl_maxfps 0` means 125, not
// unlimited. 125 covers every layer rate a Vision Pro can present, so the target is simply
// the layer rate clamped into [30, 125] — never 0, because a literal 0 would read back as
// "0" in the dumps and hide which rate we asked for.

static int      vr_pace_cvars_held;
static char     vr_pace_saved_maxfps[24], vr_pace_saved_async[24], vr_pace_saved_rmaxfps[24];
static int      vr_pace_applied_hz;          // what cl_maxfps was last set to, 0 = untouched
static char     vr_sync_mode[24] = "?";      // [overlay 0046] the client's own throttle state
static int      vr_sync_active = -1, vr_sync_state = -1;
static int      vr_sync_main_ms, vr_sync_phys_ms, vr_sync_ref_ms;
static int      vr_sync_capped_last = -1;
static int      vr_sync_act_prev = -1;       // the previous observation, for the repair
static int      vr_sync_repairs;             // how many times VR re-activated the client

// The layer rate, quantised. A median period jitters by a few microseconds, and re-setting
// cl_maxfps on that jitter would re-run CL_UpdateFrameTimes (and reset its accumulators)
// several times a second. Snap to the panel rates a headset actually presents at; anything
// else rounds to a whole Hz.
static int vr_layer_hz(void)
{
    int us = Q2_VR_LayerPeriodUs();
    if (us <= 0) return 0;
    double hz = 1e6 / (double)us;
    static const int rates[] = { 60, 72, 80, 90, 96, 100, 120 };
    for (unsigned i = 0; i < sizeof(rates) / sizeof(rates[0]); i++)
        if (fabs(hz - rates[i]) <= rates[i] * 0.05) return rates[i];
    int r = (int)(hz + 0.5);
    return r < 10 ? 10 : (r > 240 ? 240 : r);
}

// Engine thread only (Cvar_Set runs the `changed` callback, which is CL_UpdateFrameTimes).
static void vr_pace_cvars_apply(void)
{
    if (vr_pace_cvars_held && vr_layer_hz() == vr_pace_applied_hz) return;   // the common case
    cvar_t *maxfps = Cvar_FindVar("cl_maxfps");
    cvar_t *async  = Cvar_FindVar("cl_async");
    cvar_t *rmax   = Cvar_FindVar("r_maxfps");
    if (!maxfps || !async || !rmax) return;
    if (!vr_pace_cvars_held) {
        Q_strlcpy(vr_pace_saved_maxfps,  maxfps->string, sizeof vr_pace_saved_maxfps);
        Q_strlcpy(vr_pace_saved_async,   async->string,  sizeof vr_pace_saved_async);
        Q_strlcpy(vr_pace_saved_rmaxfps, rmax->string,   sizeof vr_pace_saved_rmaxfps);
        vr_pace_cvars_held = 1;
        vr_pace_applied_hz = 0;
        Cvar_Set("cl_async", "1");
        Cvar_Set("r_maxfps", "0");
    }
    int hz = vr_layer_hz();
    // MEASURED ON THE SIM, R21: the first layer periods after entry are settling and read as
    // low as 10 Hz, and the first version of this followed one of them straight to
    // `cl_maxfps 30` before the real 60 arrived a second later. No headset layer presents below
    // 60, so a reading under 45 Hz is a measurement artefact, never a rate to follow: it is
    // ignored entirely and the player's own value stands until a plausible one arrives.
    if (hz < 45) return;
    if (hz < 60)  hz = 60;
    if (hz > 125) hz = 125;                    // MAX_PHYS_HZ
    if (hz == vr_pace_applied_hz) return;
    char v[16];
    Q_snprintf(v, sizeof v, "%d", hz);
    Cvar_Set("cl_maxfps", v);
    char line[192];
    Q_snprintf(line, sizeof line,
               "VRPACE cl_maxfps=%d from=layerhz=%d was=%s cl_async=1 r_maxfps=0",
               hz, vr_layer_hz(), vr_pace_saved_maxfps);
    vr_pace_applied_hz = hz;
    Q2_VR_BlackBoxPin("pacecvars", line);
    Q2_VR_Log(line);
}

// THE OTHER CEILING, and it is the one that would look exactly like a renderer bug.
// `CL_UpdateFrameTimes` does not reach the cl_maxfps branch at all unless the client is BOTH
// `ACT_ACTIVATED` and `ca_active`: anything else picks "run at 60 fps if not active"
// (`main_msec = 16`) or, minimised, 10 fps with the refresh off entirely — and NOTHING the
// shell writes to cl_maxfps changes that. In a merged 2D+3D app whose 2D window is hidden
// while the immersive space is open, that state is one scene-phase callback away at all
// times: a literal "60 is our max" with no renderer involvement.
//
// The repair below is `CL_Activate(ACT_ACTIVATED)`, which also re-activates the AVAudioSession
// and restarts the audio unit — correct when the headset is on the player's face, WRONG when
// the app is genuinely backgrounded with the engine thread still winding down. The two are
// told apart by the app delegate: main.m's applicationDidEnterBackground /
// applicationWillEnterForeground set `vr_app_backgrounded`, and the repair is refused while it
// is set. (The R21 review found the earlier "engine thread stops first" argument was a race:
// one more frame can run before vr_thread_stop lands.)
static atomic_int vr_app_backgrounded;
void Q2_VR_SetAppBackgrounded(int on) { atomic_store(&vr_app_backgrounded, on ? 1 : 0); }

static void vr_pace_probe_sync(void)
{
    int act = -1, st = -1, mainms = 0, physms = 0, refms = 0;
    const char *mode = CL_SyncModeProbe(&act, &st, &mainms, &physms, &refms);
    Q_strlcpy(vr_sync_mode, mode ? mode : "?", sizeof vr_sync_mode);
    vr_sync_active = act; vr_sync_state = st;
    vr_sync_main_ms = mainms; vr_sync_phys_ms = physms; vr_sync_ref_ms = refms;
    // THE REPAIR. `cls.active != ACT_ACTIVATED` makes CL_UpdateFrameTimes choose "run at 60 fps
    // if not active" (or 10 fps with the refresh off, minimised) and NO value of cl_maxfps lifts
    // it — a literal 60 Hz ceiling with no renderer involvement. This function runs only from
    // the VR engine frame, i.e. only while the immersive space is open and this thread owns the
    // frame, so the state it is repairing is the one case that can reach here: the merged app's
    // 2D window went inactive because it is HIDDEN behind the immersive space. A genuine
    // background stops this thread (the immersive scene's own lifecycle), so there is no path
    // where this re-activates audio for an app the player has actually left.
    //
    // ON A TRANSITION ONLY, never per frame: CL_Activate restarts the audio unit, and calling it
    // every frame would be a permanent audio glitch rather than a fix. `act` is compared against
    // the PREVIOUS observation, so one entry into the state costs exactly one call; if the call
    // does not take (some other owner puts it straight back) the next transition, not the next
    // frame, tries again.
    if (act != Q2VR_ACT_ACTIVATED && act != vr_sync_act_prev && !atomic_load(&vr_app_backgrounded)) {
        char rep[192];
        Q_snprintf(rep, sizeof rep,
                   "VRPACE activated clsactive=%d->%d sync=%s mainms=%d - the client was not "
                   "ACT_ACTIVATED with the immersive space open, which caps the sim at %d Hz",
                   act, Q2VR_ACT_ACTIVATED, vr_sync_mode, mainms, mainms > 0 ? 1000 / mainms : 60);
        vr_sync_repairs++;
        Q2_VR_BlackBoxPin("paceact", rep);
        Q2_VR_Log(rep);
        CL_Activate(Q2VR_ACT_ACTIVATED);
        // Re-read: everything below (and the VRGPU line) must report the state the repair left
        // behind, not the one that provoked it.
        mode = CL_SyncModeProbe(&act, &st, &mainms, &physms, &refms);
        Q_strlcpy(vr_sync_mode, mode ? mode : "?", sizeof vr_sync_mode);
        vr_sync_active = act; vr_sync_state = st;
        vr_sync_main_ms = mainms; vr_sync_phys_ms = physms; vr_sync_ref_ms = refms;
        // A repair changes cl_maxfps's meaning (CL_UpdateFrameTimes reset its accumulators and
        // re-derived every budget), so the follow is re-asserted on the next frame.
        vr_pace_applied_hz = 0;
    }
    vr_sync_act_prev = act;
    // main_msec is non-zero ONLY in the whole-frame-throttle modes; in the async modes the
    // budget lives in phys_msec/ref_msec and CL_Frame never early-returns.
    const int capped = (mainms > 0);
    if (capped == vr_sync_capped_last) return;
    vr_sync_capped_last = capped;
    char line[224];
    if (capped)
        Q_snprintf(line, sizeof line,
                   "VRPACE WARNING sync=%s clsactive=%d clsstate=%d mainms=%d - CL_Frame is "
                   "whole-frame throttled at %d Hz and cl_maxfps cannot lift it",
                   vr_sync_mode, act, st, mainms, mainms > 0 ? 1000 / mainms : 0);
    else
        Q_snprintf(line, sizeof line,
                   "VRPACE sync=%s clsactive=%d clsstate=%d physms=%d refms=%d - the sim steps "
                   "every host frame", vr_sync_mode, act, st, physms, refms);
    Q2_VR_BlackBoxPin("pacesync", line);
    Q2_VR_Log(line);
}

// Engine thread, once, as the thread winds down. Restore is unconditional and idempotent.
static void vr_pace_cvars_restore(void)
{
    if (!vr_pace_cvars_held) return;
    vr_pace_cvars_held = 0;
    if (vr_pace_saved_maxfps[0])  Cvar_Set("cl_maxfps", vr_pace_saved_maxfps);
    if (vr_pace_saved_async[0])   Cvar_Set("cl_async",  vr_pace_saved_async);
    if (vr_pace_saved_rmaxfps[0]) Cvar_Set("r_maxfps",  vr_pace_saved_rmaxfps);
    char line[192];
    Q_snprintf(line, sizeof line, "VRPACE restored cl_maxfps=%s cl_async=%s r_maxfps=%s",
               vr_pace_saved_maxfps, vr_pace_saved_async, vr_pace_saved_rmaxfps);
    vr_pace_applied_hz = 0;
    Q2_VR_BlackBoxPin("pacecvars", line);
    Q2_VR_Log(line);
}

// -------------------------------------------------------------------------------------
// The adaptive divisor
// -------------------------------------------------------------------------------------
// WHY ONLY INTEGER DIVISORS. The compositor presents on ITS cadence whatever pair is
// complete; a pair that is not replaced is simply presented again (reprojected). So the
// engine's rate is not free: it is the layer rate divided by how many layer frames each
// engine frame survives. At 120 Hz an 80 fps engine does not present 80 evenly spaced
// frames — it presents each frame for one or two layer periods in a 2-3-2 beat, and a beat
// in the presentation interval is exactly the judder a fixed rate avoids. Integer divisors
// (120/60/40/30, 90/45/30) are the only cadences with a constant present interval, so the
// controller only ever chooses one.
//
// R17 chose N=2 whenever the layer period was under 10 ms and N=1 otherwise. That is a
// FIXED rule masquerading as auto: it pinned a 120 Hz headset to 60 even when the engine
// could hold 120, and it offered nothing at all to a 90 Hz layer the engine cannot hold.
// This controller measures instead. Target = the layer rate. Over a 2 s window it counts
// LATE engine frames (host frame interval longer than 1.15x the target period, which is
// the "this frame missed its slot" test, not a rate average that a few good frames hide);
// two consecutive windows over 10 % late steps the divisor UP, and five seconds of >=25 %
// headroom with almost nothing late steps it back DOWN. The asymmetry is the hysteresis:
// stepping up is cheap and quick, stepping back down has to earn it — an oscillating
// divisor would be worse than either endpoint.

#define VR_DIV_WINDOW_NS   2000000000ull
#define VR_DIV_DOWN_NS     5000000000ull
#define VR_DIV_MAX         4
#define VR_STAT_RING       256

static atomic_int vr_div_eff = 1;            // what EngineAcquire is using right now
static int        vr_div_late_windows;       // consecutive windows over the late threshold
static uint64_t   vr_div_window_start_ns;
static uint64_t   vr_div_good_since_ns;      // start of the current all-headroom stretch
static uint64_t   vr_div_cooldown_until_ns;
static unsigned   vr_div_frames, vr_div_late;
static float      vr_div_last_late_pct, vr_div_last_hz;
static int        vr_div_layer_hz;           // [R22] the layer rate the current divisor was chosen against

// Frame-time and GPU-time rings. Plain float rings with a copy-and-sort percentile: a few
// hundred samples once a second is nothing next to a frame, and an approximate percentile
// in an instrument is how a measurement round ends up arguing with itself.
static float      vr_cpu_ms[VR_STAT_RING];   static int vr_cpu_n, vr_cpu_i;
static float      vr_gpu_ms[VR_STAT_RING];   static int vr_gpu_n, vr_gpu_i;
static float      vr_comp_ms[VR_STAT_RING];  static int vr_comp_n, vr_comp_i;
static pthread_mutex_t vr_stat_mtx = PTHREAD_MUTEX_INITIALIZER;
static atomic_int vr_gpu_state;              // 0 = unprobed, 1 = timing, -1 = unavailable
static atomic_int vr_gpu_last_us;            // the newest GPU frame time, for the late test

static void vr_stat_push(float *ring, int *n, int *i, float v)
{
    ring[*i] = v;
    *i = (*i + 1) % VR_STAT_RING;
    if (*n < VR_STAT_RING) (*n)++;
}

static int vr_stat_cmp(const void *a, const void *b)
{
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

// pct in [0,100]. Returns 0 when there is nothing to report, which every reader prints as
// 0.00 — an absent instrument reads as zero, never as a plausible number.
static float vr_stat_pct(const float *ring, int n, float pct)
{
    if (n <= 0) return 0.0f;
    float copy[VR_STAT_RING];
    memcpy(copy, ring, (size_t)n * sizeof(float));
    qsort(copy, (size_t)n, sizeof(float), vr_stat_cmp);
    int idx = (int)((pct / 100.0f) * (float)(n - 1) + 0.5f);
    if (idx < 0) idx = 0;
    if (idx >= n) idx = n - 1;
    return copy[idx];
}

// The GPU sinks. Both are called from OTHER threads than the reader (`xr3_glue` on the
// engine thread, the compositor's completion handler on its own), so the ring is locked.
void Q2_VR_NoteEngineGpu(double ms)
{
    if (!(ms > 0.0) || ms > 1000.0) return;
    atomic_store(&vr_gpu_state, 1);
    atomic_store(&vr_gpu_last_us, (int)(ms * 1000.0));
    pthread_mutex_lock(&vr_stat_mtx);
    vr_stat_push(vr_gpu_ms, &vr_gpu_n, &vr_gpu_i, (float)ms);
    pthread_mutex_unlock(&vr_stat_mtx);
}

void Q2_VR_NoteCompositorGpu(double ms)
{
    if (!(ms > 0.0) || ms > 1000.0) return;
    pthread_mutex_lock(&vr_stat_mtx);
    vr_stat_push(vr_comp_ms, &vr_comp_n, &vr_comp_i, (float)ms);
    pthread_mutex_unlock(&vr_stat_mtx);
}

void Q2_VR_NoteGpuTimerUnavailable(void)
{
    int expect = 0;
    if (atomic_compare_exchange_strong(&vr_gpu_state, &expect, -1))
        Q2_VR_Log("VRGPU timer UNAVAILABLE: GL_EXT_disjoint_timer_query is not exported by "
                  "this backend - eng_ms will read 0.00 and the GPU/CPU question is open");
}

int Q2_VR_EffectivePoseDivisor(void)
{
    return atomic_load(&vr_div_eff);
}

// `q2vrdiv N` (N >= 1) is a MANUAL pin and the controller must not fight it. `q2vrdiv 0` is
// auto. `Q2_VR_PoseDivisorRaw` (q2_vr_dumps.m) is the RAW override — 0 when nobody has pinned
// one — where `Q2_VR_PoseDivisor` has already folded R17's auto rule in and so cannot tell
// "auto on a 120 Hz layer" from "pinned to 2". Exact, rather than the inference this used to
// make.
static int vr_div_is_auto(void)
{
    return Q2_VR_PoseDivisorRaw() <= 0;
}

// Called once per engine frame with the host frame's wall time. Owns the divisor.
static void vr_pace_sample(uint64_t frame_ns)
{
    const uint64_t now = vr_now_ns();
    const int hz = vr_layer_hz();
    const int div = atomic_load(&vr_div_eff);
    const double frame_ms = (double)frame_ns / 1e6;
    // The late test is on the WORSE of the two producers. `frame_ms` is the CPU cost of the
    // host frame measured from the acquired pose to the release (the divisor's own wait is
    // deliberately outside it — a well-paced engine would otherwise read exactly the target
    // period and never show headroom), and the newest GPU frame time is the other half. The
    // eye-slot and in-flight gates already push GPU backpressure into the CPU number, so this
    // is belt and braces rather than a second opinion, and it costs one atomic load.
    const double gpu_ms = (double)atomic_load(&vr_gpu_last_us) / 1000.0;
    const double work_ms = frame_ms > gpu_ms ? frame_ms : gpu_ms;

    pthread_mutex_lock(&vr_stat_mtx);
    vr_stat_push(vr_cpu_ms, &vr_cpu_n, &vr_cpu_i, (float)frame_ms);
    pthread_mutex_unlock(&vr_stat_mtx);

    if (!vr_div_window_start_ns) { vr_div_window_start_ns = now; vr_div_good_since_ns = now; }
    if (hz <= 0) return;

    // [R23] THE LAYER RATE CHANGED: KEEP THE ENGINE'S TARGET RATE, DO NOT RESET TO 1.
    // The divisor is an INTEGER count of layer frames per engine frame — it has to be, because
    // an 80 fps engine on a 120 Hz layer presents in a 2-3-2 beat, which is exactly the judder
    // this controller exists to avoid. Being integer, it is only ever correct RELATIVE to the
    // layer rate it was chosen against: divisor 2 on a 120 Hz layer targets 60, and the same
    // divisor 2 on a 60 Hz layer targets 30 — wrong by precisely the factor the rate moved by.
    // A controlled A/B (2026-09-06) caught that live: the visionOS layer stepped
    // 120 -> 60 mid-test and the divisor sat at 2 (a 30 Hz target!) for five seconds until the
    // headroom hysteresis walked it down. So the divisor MUST be re-chosen on a rate change.
    //
    // R22 re-chose it as 1, and that was the wrong answer — it fed a throttle oscillation.
    // Measured in the headset (2026-09-07): at >=90 % GPU load visionOS flips the layer between
    // a 60 Hz and a 40 Hz rate, and while throttled every timer reads 3x. Snapping to 1 on each
    // flip jumps the engine to the FULL new layer rate, which re-saturates the GPU and provokes
    // the next flip; the controller then spends two windows climbing back, by which time the
    // layer has moved again. The loop is self-sustaining and the divisor never settles.
    //
    // The fix is to treat the ENGINE TARGET, not the divisor, as the thing being preserved.
    // With old target T = H_old / d_old, pick the smallest divisor whose new target does not
    // exceed T: d = ceil(H_new / T), with a 0.2 slack so a rate that divides almost exactly
    // (120/2 = 60 -> 60 Hz layer) lands on the lower divisor instead of one step too high.
    //   120/3 = 40 Hz  ->  60 Hz layer  =>  d=2  (40 -> 30, not a jump to 60)
    //   120/2 = 60 Hz  ->  60 Hz layer  =>  d=1  (the .25 bug: 30 Hz target for 5 s)
    //   60 /1 = 60 Hz  -> 120 Hz layer  =>  d=2  (still 60, not a doubling to 120)
    //   60 /2 = 30 Hz  -> 120 Hz layer  =>  d=4
    // The pick is deliberately CONSERVATIVE (it never raises the engine's rate), and it does
    // not have to be perfect: the step-down hysteresis below still runs, so five seconds of
    // real headroom heals an over-cautious divisor by itself.
    //
    // Readings below 45 Hz are settling artefacts, never a real panel rate (same rule
    // vr_pace_cvars_apply applies to cl_maxfps), and are not treated as a change. `cl_maxfps`
    // needs no hook here: vr_pace_cvars_apply runs every host frame and already re-applies
    // itself whenever vr_layer_hz() moves off vr_pace_applied_hz, so both halves of the pacing
    // follow the same event.
    if (hz >= 45 && hz != vr_div_layer_hz) {
        const int was = vr_div_layer_hz;
        vr_div_layer_hz = hz;
        // Restart the measurement window and the late/headroom state unconditionally: the
        // samples in flight were taken against a target period that no longer exists.
        vr_div_frames = vr_div_late = 0;
        vr_div_late_windows = 0;
        vr_div_window_start_ns = now;
        vr_div_good_since_ns = now;
        vr_div_cooldown_until_ns = now + VR_DIV_WINDOW_NS;   // the normal one-window cooldown
        // A manual `q2vrdiv N` pin WINS: the controller measures under it and never fights it.
        if (was && vr_div_is_auto()) {
            const double old_target = (double)was / (double)(div > 0 ? div : 1);
            int next = (int)ceil((double)hz / old_target - 0.2);
            if (next < 1) next = 1;
            if (next > VR_DIV_MAX) next = VR_DIV_MAX;
            if (next != div) {
                atomic_store(&vr_div_eff, next);
                char line[192];
                Q_snprintf(line, sizeof line,
                           "VRDIV to=%d from=%d why=layerchange layerhz=%d enghz=%.1f late=%.1f%% targethz=%.1f",
                           next, div, hz, vr_div_last_hz, vr_div_last_late_pct,
                           (double)hz / (double)next);
                Q2_VR_BlackBoxPin("div", line);
                Q2_VR_Log(line);
            }
        }
        return;
    }

    const double target_ms = 1000.0 / ((double)hz / (double)(div > 0 ? div : 1));
    vr_div_frames++;
    if (work_ms > target_ms * 1.15) vr_div_late++;
    if (work_ms > target_ms * 0.75) vr_div_good_since_ns = now;   // headroom stretch broken

    if (now - vr_div_window_start_ns < VR_DIV_WINDOW_NS) return;

    const double win_s = (double)(now - vr_div_window_start_ns) / 1e9;
    const float late_pct = vr_div_frames ? 100.0f * (float)vr_div_late / (float)vr_div_frames : 0.0f;
    const float eng_hz = win_s > 0.05 ? (float)(vr_div_frames / win_s) : 0.0f;
    vr_div_last_late_pct = late_pct;
    vr_div_last_hz = eng_hz;
    const unsigned frames = vr_div_frames;
    vr_div_frames = vr_div_late = 0;
    vr_div_window_start_ns = now;

    if (!vr_div_is_auto()) {                    // a manual q2vrdiv pin: follow it, measure only
        int pinned = Q2_VR_PoseDivisor();
        if (pinned != div) atomic_store(&vr_div_eff, pinned);
        vr_div_late_windows = 0;
        return;
    }
    if (now < vr_div_cooldown_until_ns || frames < 8) return;

    int next = div;
    const char *why = NULL;
    if (late_pct > 10.0f) {
        if (++vr_div_late_windows >= 2 && div < VR_DIV_MAX) { next = div + 1; why = "late"; }
    } else {
        vr_div_late_windows = 0;
        if (div > 1 && late_pct < 2.0f && now - vr_div_good_since_ns >= VR_DIV_DOWN_NS) {
            next = div - 1; why = "headroom";
        }
    }
    if (next == div) return;

    atomic_store(&vr_div_eff, next);
    vr_div_late_windows = 0;
    vr_div_good_since_ns = now;
    vr_div_cooldown_until_ns = now + VR_DIV_WINDOW_NS;
    char line[192];
    Q_snprintf(line, sizeof line,
               "VRDIV to=%d from=%d why=%s layerhz=%d enghz=%.1f late=%.1f%% targethz=%.1f",
               next, div, why, hz, eng_hz, late_pct, (double)hz / (double)next);
    Q2_VR_BlackBoxPin("div", line);
    Q2_VR_Log(line);
}

// The one line that says whether we are GPU- or CPU-bound. `eng_ms` is the engine's own GPU
// work for a whole host frame (both eyes plus the UI pass), measured with
// GL_EXT_disjoint_timer_query inside xr3_glue and read back several frames later so nothing
// stalls; `comp_ms` is the compositor's command buffer (gpuEndTime - gpuStartTime, fed in
// by the shell); `cpu_ms` is the engine host frame wall time on this thread. Two numbers
// under the frame budget with a late fraction says CPU; eng_ms at the budget says GPU.
void Q2_VR_DumpGpuFields(char *out, int outsz)
{
    pthread_mutex_lock(&vr_stat_mtx);
    float e50 = vr_stat_pct(vr_gpu_ms, vr_gpu_n, 50), e95 = vr_stat_pct(vr_gpu_ms, vr_gpu_n, 95);
    float c50 = vr_stat_pct(vr_comp_ms, vr_comp_n, 50);
    float p50 = vr_stat_pct(vr_cpu_ms, vr_cpu_n, 50), p95 = vr_stat_pct(vr_cpu_ms, vr_cpu_n, 95);
    int en = vr_gpu_n, cn = vr_comp_n;
    pthread_mutex_unlock(&vr_stat_mtx);
    const int st = atomic_load(&vr_gpu_state);
    Q_snprintf(out, outsz,
               "VRGPU eng_ms=%.2f/%.2f comp_ms=%.2f cpu_ms=%.2f/%.2f engwinhz=%.1f late=%.1f%% "
               "div=%d layerhz=%d clmaxfps=%d timer=%s samples=%d/%d "
               "sync=%s clsactive=%d mainms=%d physms=%d actrepairs=%d",
               e50, e95, c50, p50, p95, vr_div_last_hz, vr_div_last_late_pct,
               atomic_load(&vr_div_eff), vr_layer_hz(), vr_pace_applied_hz,
               st > 0 ? "ext" : (st < 0 ? "absent" : "probing"), en, cn,
               vr_sync_mode, vr_sync_active, vr_sync_main_ms, vr_sync_phys_ms,
               vr_sync_repairs);
}

// Once a second, on the engine thread, pinned AND logged — the same cadence VRCLOCK uses on
// the compositor side, so a black box recovered from a jetsam kill carries both halves of
// the frame. Pinned under its own key so `q2vrpace` can echo it the way it echoes clock,
// anchor and slot (that echo is a one-line change in q2_vr_dumps.m; until it lands the same
// fields are appended to PACENOW itself, which is why nothing depends on it).
// A VR session's pacing state starts clean, exactly as its counters do: `Q2_VR_PaceReset` is
// called on ENTRY (and by `q2vrpace reset`), so "the numbers from this session" means the same
// thing for the divisor and the percentile rings as it already did for the frame counts. The
// cvar stash is deliberately NOT touched here — it is owned by the engine thread's lifetime,
// not by a counter reset, and clearing it would strand the player's cl_maxfps.
static void vr_pace_controller_reset(void)
{
    atomic_store(&vr_div_eff, 1);
    vr_div_late_windows = 0;
    vr_div_window_start_ns = vr_div_good_since_ns = vr_div_cooldown_until_ns = 0;
    vr_div_frames = vr_div_late = 0;
    vr_div_last_late_pct = vr_div_last_hz = 0.0f;
    vr_div_layer_hz = 0;                 // [R22] re-latched from the first plausible reading
    pthread_mutex_lock(&vr_stat_mtx);
    vr_cpu_n = vr_cpu_i = vr_gpu_n = vr_gpu_i = vr_comp_n = vr_comp_i = 0;
    pthread_mutex_unlock(&vr_stat_mtx);
}

static void vr_pace_second(void)
{
    static uint64_t next_ns;
    uint64_t now = vr_now_ns();
    if (now < next_ns) return;
    next_ns = now + 1000000000ull;
    char line[320];
    Q2_VR_DumpGpuFields(line, sizeof line);
    Q2_VR_BlackBoxPin("gpu", line);
    Q2_VR_Log(line);
}
// One line, every number a MEASUREMENTS row for VR pacing needs. Rates are derived from the
// window the counters actually cover, so a dump taken ten seconds after a reset and one
// taken two minutes after it are directly comparable.
void Q2_VR_DumpPaceFields(char *out, int outsz)
{
    unsigned long long pubs = atomic_load(&pace_pub), rep = atomic_load(&pace_repres);
    unsigned long long stale = atomic_load(&pace_stale), eng = atomic_load(&pace_engine);
    uint64_t first = atomic_load(&pace_first_ns), last = atomic_load(&pace_last_ns);
    double win = (last > first) ? (double)(last - first) / 1e9 : 0.0;
    Q_snprintf(out, outsz,
               "PACENOW windowsec=%.2f pubs=%llu comphz=%.1f repres=%llu worstgapms=%.2f "
               "engframes=%llu enghz=%.1f engstale=%llu pubepoch=%d pubrefused=%d "
               "rendezvous=%d owner=%s panelframes=%llu paneleyes=both",
               win, pubs, win > 0.05 ? (double)pubs / win : 0.0, rep,
               (double)atomic_load(&pace_worst_gap_ns) / 1e6,
               eng, win > 0.05 ? (double)eng / win : 0.0, stale,
               VID_iOS_XR3_PubEpoch(), VID_iOS_XR3_PubRefused(),
               vr_rendezvous_on ? 1 : 0,
               Q2_VR_FrameOwner() == Q2VR_OWNER_VR ? "vrthread" : "displaylink",
               atomic_load(&pace_panel));
    // [R21] APPENDED, never inserted (the suite reads PACENOW by field, and R7a-2 anchors on
    // `panelframes`/`paneleyes`). The GPU/CPU instrument rides the line `q2vrpace` already
    // prints, so a headset reading needs no new console command; VRGPU is also pinned and
    // logged in its own right once a second. Every field name here is unique on the line —
    // the window rate is `engwinhz`, not a second `enghz`.
    char gpu[320];
    Q2_VR_DumpGpuFields(gpu, sizeof gpu);
    Q_strlcat(out, " ", outsz);
    Q_strlcat(out, gpu + 6, outsz);              // past the "VRGPU " tag
}

static void vr_wait_rel_ns(pthread_cond_t *cv, pthread_mutex_t *m, uint64_t ns)
{
    struct timespec ts = { .tv_sec = (time_t)(ns / 1000000000ull),
                           .tv_nsec = (long)(ns % 1000000000ull) };
    pthread_cond_timedwait_relative_np(cv, m, &ts);
}

// Compositor side. Publishes both eyes' pose+tangents and returns the id it got.
uint64_t Q2_VR_Publish(const q2_vr_pose_t *p)
{
    uint64_t id;
    pthread_mutex_lock(&vr_mtx);
    vr_published = *p;
    id = vr_published.id = ++vr_pub_id;
    pthread_cond_broadcast(&vr_cv);
    pthread_mutex_unlock(&vr_mtx);
    // Pacing: the compositor's own cadence, measured at the one statement every VR frame
    // passes through exactly once.
    uint64_t now = vr_now_ns(), prev = atomic_exchange(&pace_last_ns, now);
    if (!atomic_load(&pace_first_ns)) atomic_store(&pace_first_ns, now);
    else if (prev && now - prev > atomic_load(&pace_worst_gap_ns))
        atomic_store(&pace_worst_gap_ns, now - prev);
    atomic_fetch_add(&pace_pub, 1);
    return id;
}

// Compositor side. Waits up to 14 ms for the engine to have rendered `id`. Returns true if
// it did. On false the caller re-presents the PREVIOUS pair against the anchor THAT pair
// was rendered with — a dropped frame then costs latency, never a jolt.
bool Q2_VR_WaitRendered(uint64_t id)
{
    bool ok;
    pthread_mutex_lock(&vr_mtx);
    // [R8] LOOP ON THE PREDICATE, not on one wait. `Q2_VR_EngineRelease` broadcasts, so a
    // release of an OLDER id (or a `SetRendezvousActive` broadcast) woke this wait early and
    // it returned !fresh after about a millisecond of its 14 ms budget — a re-present, and a
    // stale pair, on a frame that had 13 ms of headroom left. A condvar wait without a
    // predicate loop is a bug by construction; the deadline, not the wakeup, ends the wait.
    uint64_t deadline = vr_now_ns() + (uint64_t)Q2VR_SHELL_WAIT_MS * 1000000ull;
    while (vr_rendered_id < id && vr_rendezvous_on) {
        uint64_t now = vr_now_ns();
        if (now >= deadline) break;
        // Relative waits only: Apple has no `pthread_condattr_setclock`, so the remaining
        // budget is recomputed each time round rather than pinned to an absolute clock.
        vr_wait_rel_ns(&vr_cv, &vr_mtx, deadline - now);
    }
    ok = vr_rendered_id >= id;
    pthread_mutex_unlock(&vr_mtx);
    if (!ok) atomic_fetch_add(&pace_repres, 1);   // this frame re-presents the previous pair
    return ok;
}

// Engine side. Blocks up to 20 ms for an id newer than the last one it rendered, then
// MEMCPYS the published pair under the lock into a private copy — a render can never read
// a pair half-rewritten. On timeout it returns the previous pair and renders again rather
// than stalling the game loop; the compositor reprojects a repeat far better than it
// survives a hitch.
static uint64_t vr_engine_last;
bool Q2_VR_EngineAcquire(q2_vr_pose_t *out)
{
    bool fresh;
    // [R17] THE POSE DIVISOR. Under the free-running compositor a pose is published every
    // LAYER frame (120 Hz on the test headset) and the engine renders at ~60; taking every
    // pose the instant it lands would run the engine at whatever its frame time happens to
    // be and present the result with a 2-3-2 layer-frame beat. Waiting for the Nth pose
    // after the last one rendered gives a steady cadence (N=2 at 120 Hz: exactly two layer
    // frames per engine frame). A predicate loop with a deadline, never a single wait: the
    // broadcast fires on every publish and on every release.
    // [R21] The divisor is now the ADAPTIVE one (vr_pace_sample owns it, and honours a
    // manual `q2vrdiv N` pin unchanged); R17's fixed "2 when the layer is faster than
    // 100 Hz" is gone, because it pinned a 120 Hz headset to 60 whether or not the engine
    // could have held 120.
    const int divN = Q2_VR_EffectivePoseDivisor();
    const uint64_t want = vr_engine_last + (uint64_t)(divN > 0 ? divN : 1);
    pthread_mutex_lock(&vr_mtx);
    if (vr_pub_id < want && vr_rendezvous_on) {
        uint64_t deadline = vr_now_ns() + (uint64_t)Q2VR_ENGINE_WAIT_MS * 1000000ull;
        while (vr_pub_id < want && vr_rendezvous_on) {
            uint64_t now = vr_now_ns();
            if (now >= deadline) break;
            vr_wait_rel_ns(&vr_cv, &vr_mtx, deadline - now);
        }
    }
    fresh = vr_pub_id > vr_engine_last;
    *out = vr_published;
    vr_engine_last = vr_pub_id;
    pthread_mutex_unlock(&vr_mtx);
    if (!fresh) atomic_fetch_add(&pace_stale, 1);  // the 20 ms wait expired: re-render the pair
    return fresh;
}

void Q2_VR_EngineRelease(uint64_t id)
{
    pthread_mutex_lock(&vr_mtx);
    if (id > vr_rendered_id) vr_rendered_id = id;
    pthread_cond_broadcast(&vr_cv);
    pthread_mutex_unlock(&vr_mtx);
    atomic_fetch_add(&pace_engine, 1);
}

// Deactivation broadcasts UNCONDITIONALLY. Never leave either side blocked on a rendezvous
// nobody will publish to — that is the teardown wedge both donors catalogued, and the
// symptom is an exit path whose bounded wait expires while the space is dismissed out from
// under a thread that is still inside it.
void Q2_VR_SetRendezvousActive(int on)
{
    pthread_mutex_lock(&vr_mtx);
    vr_rendezvous_on = on != 0;
    if (!on) { vr_engine_last = 0; vr_pub_id = 0; vr_rendered_id = 0; memset(&vr_published, 0, sizeof(vr_published)); }
    // [R21] Was "atomics only". It now also takes `vr_stat_mtx` (the percentile rings) for
    // a few microseconds. That is still safe under `vr_mtx`: no path anywhere takes
    // `vr_mtx` while holding `vr_stat_mtx`, so the two can never invert.
    if (on) Q2_VR_PaceReset();
    // [R23] The entry watch is a per-SESSION instrument for the same reason the pacing
    // counters are: "the numbers from this VR session" must not need anyone to remember to
    // reset them first, and the black entry is a per-ENTRY state by report.
    Q2_VR_ArmEntryWatch(on);
    // A session's counters start at zero on ENTRY, so "the numbers from this VR session" is
    // what a dump means without anybody having to remember to reset it first.
    pthread_cond_broadcast(&vr_cv);
    pthread_mutex_unlock(&vr_mtx);
}

// =====================================================================================
// Frame ownership
// =====================================================================================
// Tri-state, asserted in the black box on every transition. "Stopping is a request plus a
// poll, never a join": the engine thread can be inside a bounded condvar wait, and a join
// from the MainActor would hold the main thread for as long as that wait, which is exactly
// how a dismissal ends up racing a live render.

static atomic_int   vr_owner = Q2VR_OWNER_LINK;
static atomic_int   vr_thread_stop;
static atomic_int   vr_thread_running;
static pthread_t    vr_thread;

int Q2_VR_FrameOwner(void)        { return atomic_load(&vr_owner); }
int Q2_VR_EngineThreadRunning(void) { return atomic_load(&vr_thread_running); }

static void vr_pin_owner(void)
{
    char line[96];
    Q_snprintf(line, sizeof(line), "OWNER frame=%s thread=%d",
               atomic_load(&vr_owner) == Q2VR_OWNER_VR ? "vrthread" : "displaylink",
               atomic_load(&vr_thread_running));
    Q2_VR_BlackBoxPin("owner", line);
    Q2_VR_Log(line);
}

// =====================================================================================
// Pose composition
// =====================================================================================
// The published pose is in the compositor's world: metres, y-up, ARKit right-handed. The
// engine wants Quake units and Euler degrees. The conversion lives HERE and not in Swift so
// that the one number every part of it depends on — the world scale — is read from a single
// place the console can change while the headset is on.

static q2_vr_pose_t vr_frame;          // engine thread's private copy of the acquired pair
static atomic_int   vr_have_pose;
static float        vr_last_headyaw, vr_last_headpitch;

// The head yaw the LAST engine frame acquired, for the per-frame yaw trace (R3). Identity,
// not intent: it is the number the composition used, read from the same place the
// composition reads it, so the trace's residual column is a real subtraction and not two
// sources being compared.
float Q2_VR_LastHeadYaw(void) { return vr_last_headyaw; }

// [vr R4] The pair this engine frame acquired, hands included. Handed to the input step as an
// opaque pointer so the hands module reads the head and the hands out of ONE publish — the
// alternative, asking the Sense layer again on the engine thread, would sample a hand from a
// different instant than the head the frame is being rendered against, and the disagreement
// would only ever be visible while the player moves.
const void *Q2_VR_AcquiredPose(void) { return &vr_frame; }

// Per-eye: fill the engine's VR gate for THIS eye, then let the ordinary frame path run.
static void vr_apply_eye(int eye)
{
    const float ws = Q2_VR_WorldScale();
    const q2_vr_eye_t *e = &vr_frame.eye[eye & 1];

    q2vr.active = 1;
    q2vr.eye = eye & 1;
    q2vr.pose_valid = atomic_load(&vr_have_pose);
    // R3: `yaw_relative` no longer means "add the game's own view yaw". It now selects the
    // ONE engine-side term the camera may take — the server's own re-orientation
    // (ps.pmove.delta_angles[YAW]), a step function set on a teleport or a spawn that is
    // neither predicted nor lerped. Everything else about the yaw is composed here.
    q2vr.yaw_relative = 1;
    q2vr.yaw_from_pose = 0;         // the engine sets it back to 1 at the site that uses it
    q2vr.tan_l = e->tanL; q2vr.tan_r = e->tanR;
    q2vr.tan_u = e->tanU; q2vr.tan_d = e->tanD;

    // THE POSE, WHOLE, FROM THIS FRAME'S PUBLISHED PAIR (R3 — the look-jitter fix).
    //
    // What R2 did and why it shook: the head yaw went OUT through cl.viewangles and the
    // render read it back through the GAME'S view yaw, so the camera's yaw was produced by
    // the client simulation. `CL_UpdateCmd` runs on the sim tick, not on every rendered
    // frame — with cl_async 0 and a cl_maxfps under the compositor's ~90 Hz a large fraction
    // of VR frames advance no sim at all (the same early return the eye-pair fix already
    // works around). So the pose was fresh and the yaw was one to two ticks old, the
    // compositor reprojected against the pose it PUBLISHED, and the residual — non-zero only
    // while the head turns — was the jitter. Pitch and roll were always written straight from
    // the pose and never shook, which is the tell.
    //
    // So the yaw is composed here, from two values that are both current this frame: the body
    // yaw the stick and the recentre own, and the head yaw out of the acquired pair. The
    // angles the client SENDS still come from the same head one step earlier and may lag a
    // sim tick; that is the server's business and no longer the camera's (guide 12.7).
    q2vr.viewangles[PITCH] = vr_frame.headPitchDeg;
    q2vr.viewangles[YAW]   = Q2_VR_BodyYaw() + vr_frame.headYawDeg;
    q2vr.viewangles[ROLL]  = vr_frame.headRollDeg;

    // The 2D redirect. `ui_draw` is eye 0 only: the 2D stream is drawn ONCE per host frame
    // into its own texture and composited as a quad, so the same pixels are never rasterised
    // into both eye images (which is what the shipped 3D path does, and must, because it has
    // nowhere else to put them).
    q2vr.ui_redirect = VID_iOS_XR3_UIReady();
    // [R11] ...and WHICH eye that is, is now a setting. `vr_ui_eye` 0 keeps the shipped
    // arrangement, 1 moves the bracket to eye 1, and 2 takes it off the eyes entirely (the
    // pass below, after both of them). The reason is the one asymmetry left: the bracket
    // BINDS ANOTHER FRAMEBUFFER in the middle of one eye's render, which ends that eye's
    // Metal pass and re-opens it, and it has always been eye 0 — the eye the reports name for the
    // constant jitter. Anything that mode 2 makes go away was caused by that interruption.
    q2vr.ui_only = 0;
    {
        int m = Q2_VR_UIEye();
        q2vr.ui_draw = (q2vr.ui_redirect && m < 2 && (eye & 1) == m);
    }
    q2vr.ui_begin = VID_iOS_XR3_UIBegin;
    q2vr.ui_end   = VID_iOS_XR3_UIEnd;
    // [R22] The R10 "VR Stats" block is gone with its settings row (retired in R21): nothing
    // composes the text any more, so the producer is not wired. `q2vr.stats_text` stays NULL
    // and overlay 0035's draw — one predicate per 2D pass — never fires.

    // R7a — THE TWO OFFSETS, SEPARATED, because they live in different spaces and the whole
    // of Q-VR8 item 2 was rotating them by one basis (shared.h carries the mechanism).
    //
    // `bodyofs` is the head in PLAY space: it comes from `baseFromWorld * deviceAnchor`, whose
    // axes are pinned to the recentre yaw and do not turn when the head turns. The engine
    // rotates it by a yaw-only basis built from `body_yaw` below.
    //
    // `eyeofs` is this eye's offset from the head, out of the drawable's own `deviceFromEye`.
    // That one IS head-local, and the engine rotates it by the finished view angles, exactly
    // as it always did.
    q2vr.bodyofs[0] = vr_frame.headFwd   * ws;
    q2vr.bodyofs[1] = vr_frame.headRight * ws;
    q2vr.bodyofs[2] = vr_frame.headUp    * ws;
    q2vr.body_yaw   = Q2_VR_BodyYaw();
    q2vr.eyeofs[0]  = e->ofsFwd   * ws;
    q2vr.eyeofs[1]  = e->ofsRight * ws;
    q2vr.eyeofs[2]  = e->ofsUp    * ws;
    // [R17] `q2vrmono 1`: both eyes from eye 0's offset. The tangents stay per view (the
    // composite maps each image onto ITS view's frustum), so what this removes is only the
    // stereo baseline. A per-eye difference that survives mono is not in the engine's pair.
    if (Q2_VR_Mono()) {
        const q2_vr_eye_t *e0 = &vr_frame.eye[0];
        q2vr.eyeofs[0] = e0->ofsFwd   * ws;
        q2vr.eyeofs[1] = e0->ofsRight * ws;
        q2vr.eyeofs[2] = e0->ofsUp    * ws;
    }

    // Synthetic pose OVERRIDE (`q2vrpose`) — the POSITION half only. The ANGLES were folded
    // into `vr_frame` at the top of the engine frame, before the input step ran, so the body
    // yaw seed, the aim source, the dumps and this composition all see ONE effective head
    // (R3: re-assigning the yaw here would drop the body yaw the composition above adds, and
    // a suite would then assert a camera the shipping path never builds). The eye offset is
    // kept: overriding the head must not also collapse the stereo pair, or the assertion that
    // the pair differs would pass for the wrong reason.
    {
        float of, orr, ou;
        if (Q2_VR_PoseOverride(NULL, NULL, &of, &orr, &ou)) {
            // R7a: the override is a HEAD position, so it replaces the head half and leaves
            // the eye half alone — which is also what makes it a valid injection for the
            // residual instrument, since the two halves are now separately assertable.
            q2vr.bodyofs[0] = of;
            q2vr.bodyofs[1] = orr;
            q2vr.bodyofs[2] = ou;
            q2vr.pose_valid = 1;
        }
    }

    // Near plane, engine-side. gl_znear is CVAR_CHEAT: written as a cvar it works in single
    // player and is silently refused on any server, so it is a value here, not a `set`.
    // 0.1 m matches the compositor's own near plane, which is what makes the composite's
    // conversion a single reciprocal instead of an algebraic remap of two unrelated ranges.
    // [R10 item 2] THIS EYE'S OWN near plane, when the compositor filled one. The pose-level
    // value is eye 0's and was used for both eyes; the composite converts each eye's depth
    // against the constant it was RENDERED with, so the two have to be the same per eye or
    // eye 1 reprojects wrong. The fallback chain is unchanged for a shell that fills neither.
    q2vr.znear = (e->znear_m > 0.01f ? e->znear_m
                 : (vr_frame.znear_m > 0.01f ? vr_frame.znear_m : 0.1f)) * ws;

    // Listener basis: the head's, not the body's (see entities.c). Built from the same
    // angles the frame renders with, so audio and image cannot disagree — which after R3
    // means the SAME composition, not the game's own view yaw it used to be built from.
    {
        vec3_t ang = { vr_frame.headPitchDeg,
                       q2vr.viewangles[YAW] + q2vr.server_yaw,
                       vr_frame.headRollDeg };
        vec3_t f, r, u;
        AngleVectors(ang, f, r, u);
        VectorCopy(f, q2vr.listener_axis[0]);
        VectorCopy(r, q2vr.listener_axis[1]);
        VectorCopy(u, q2vr.listener_axis[2]);
        q2vr.listener_valid = q2vr.pose_valid;
    }
}

// [R7a item 2] Sampled once per WORLD frame, after the pair is rendered, on the engine
// thread — the only thread that can see both `vr_frame` (the pose that was published) and
// `q2vr.vieworg` (the origin the render used), and see them for the same frame.
//
// The comparison is against the LAST eye rendered (`q2vr.eye`, which is eye 1), because the
// gate still holds that eye's numbers at this point. Skipped when `q2vrpose` is overriding
// the position: the injected head is not the published one, and an instrument that reported
// the injection as an error would cry wolf through every synthetic-pose suite case.
static void vr_pose_residual_sample(void)
{
    const float ws = Q2_VR_WorldScale();
    vec3_t pang, pf, pr, pu, vang, vf, vr, vu, expect, actual, diff;
    float of, orr, ou;

    if (ws < 1e-3f || !q2vr.pose_valid || !atomic_load(&vr_have_pose)) return;
    if (Q2_VR_PoseOverride(NULL, NULL, &of, &orr, &ou)) return;

    const q2_vr_eye_t *e = &vr_frame.eye[q2vr.eye & 1];

    // The play basis: yaw only, and the yaw is the BODY's, not the view's.
    pang[PITCH] = 0.0f;
    pang[YAW]   = q2vr.body_yaw + q2vr.server_yaw;
    pang[ROLL]  = 0.0f;
    AngleVectors(pang, pf, pr, pu);
    // The view basis: the full head, exactly as the frame composed it.
    vang[PITCH] = vr_frame.headPitchDeg;
    vang[YAW]   = q2vr.body_yaw + vr_frame.headYawDeg + q2vr.server_yaw;
    vang[ROLL]  = vr_frame.headRollDeg;
    AngleVectors(vang, vf, vr, vu);

    VectorClear(expect);
    VectorMA(expect, vr_frame.headFwd   * ws, pf, expect);
    VectorMA(expect, vr_frame.headRight * ws, pr, expect);
    VectorMA(expect, vr_frame.headUp    * ws, pu, expect);
    VectorMA(expect, e->ofsFwd   * ws, vf, expect);
    VectorMA(expect, e->ofsRight * ws, vr, expect);
    VectorMA(expect, e->ofsUp    * ws, vu, expect);
    expect[2] += q2vr.rise_applied;

    VectorSubtract(q2vr.vieworg, q2vr.baseorg, actual);
    VectorSubtract(actual, expect, diff);
    float m = VectorLength(diff) / ws;
    if (!isfinite(m)) return;

    resid_sum_m += m;
    resid_n++;
    if (m > resid_worst_m) resid_worst_m = m;
    // The ring keeps the WORST offenders, not the most recent: a second of calm at the end of
    // a session must not evict the frame that shook.
    int slot = -1;
    if (resid_rn < VR_RESID_RING) {
        slot = resid_ri;
        resid_ri = (resid_ri + 1) % VR_RESID_RING;
        resid_rn++;
    } else {
        int worst = 0;
        for (int i = 1; i < VR_RESID_RING; i++)
            if (resid_ring[i].m < resid_ring[worst].m) worst = i;
        if (m > resid_ring[worst].m) slot = worst;
    }
    if (slot >= 0) {
        resid_ring[slot].m = m;
        resid_ring[slot].headyaw = vr_frame.headYawDeg;
        resid_ring[slot].dist_m = sqrtf(vr_frame.headFwd * vr_frame.headFwd +
                                        vr_frame.headRight * vr_frame.headRight +
                                        vr_frame.headUp * vr_frame.headUp);
        resid_ring[slot].ms = (unsigned)Sys_Milliseconds();
    }
}

// Clears `active` and NOTHING ELSE, deliberately. Every consumer of this block in the engine
// is gated on `q2vr.active &&`, so one flag disarms all of them, and the sub-fields then
// survive to say what the last VR frame actually DID — which is what the *NOW dumps report.
// Zeroing them here instead made every dump read "off": the console runs on the engine thread
// at the top of the next frame, which is after this call and before the frame that would set
// them again, so the instrument could only ever see the cleared state. Identity, not intent.
static void vr_clear_gate(void)
{
    q2vr.active = 0;
    q2vr.pose_valid = 0;
}

// =====================================================================================
// Two-phase entry — sizing the eye targets
// =====================================================================================
// Phase 1 opens the space; phase 2 commits the render size once the FIRST drawable has
// reported the size of its PHYSICAL colour texture. Never the logical viewport: that is the
// foveation-expanded raster area, and sizing from it asked a donor's engine for roughly ten
// times the pixels it needed and cost a whole device round. Never the panel pixel budget
// either — that formula shapes a 16:9 screen, and an eye target is nearly square.

static atomic_int vr_phys_w, vr_phys_h;      // physical colour texture, per eye
static atomic_int vr_committed_w, vr_committed_h;

// [R20] THE VR ANTI-ALIASING ROW. 0 = off, 2 = 2x, 4 = 4x, and anything else is snapped into
// that set here rather than at every reader. Cached on `vr_gen` — the counter the settings
// sheet and `q2vrset` both bump LAST, after the value is stored — because the engine thread
// asks for this once per eye and NSUserDefaults is not a per-frame lookup, while the budget
// on the compositor thread asks for it once per size plan.
//
// [R23] THERE IS NO LONGER A ROW — THIS IS A DEV-CONSOLE SWITCH. R21 defaulted the row to
// Off after no difference was visible; the 1.0.11.25 verdict is blunter ("killed
// FPS"), so VisionShell's Anti-aliasing row and its stored key are both gone (settings stamp
// 5 force-deletes `vr_msaa` from the store). The only writer left is `q2vrset vr_msaa N` from
// the dev console, which writes the same key and bumps `vr_gen` exactly as the sheet used to
// — so this function keeps its shape and simply reads 0 for every player, while the MSAA
// backend in xr3_glue stays testable on the next headset without resurrecting deleted code.
// An absent key IS the default here, which is why no code constant has to be kept in sync
// with Swift any more. xr3_glue still clamps whatever is asked for to GL_MAX_SAMPLES and
// falls back to none, loudly, and `vr_msaa_bytes` therefore budgets 0 by default.
static _Atomic int vr_msaa_cached = -1;
static _Atomic int vr_msaa_gen    = -1;

int Q2_VR_MsaaWanted(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    const int gen = (int)[d integerForKey:@"vr_gen"];
    const int cached = atomic_load(&vr_msaa_cached);
    if (cached >= 0 && gen == atomic_load(&vr_msaa_gen)) return cached;
    int v = [d objectForKey:@"vr_msaa"] ? (int)[d integerForKey:@"vr_msaa"] : 0;
    v = (v < 2) ? 0 : (v < 4 ? 2 : 4);
    atomic_store(&vr_msaa_cached, v);
    atomic_store(&vr_msaa_gen, gen);
    return v;
}

static float vr_render_scale(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    float q = [d objectForKey:@"vr_quality"] ? (float)[d floatForKey:@"vr_quality"] : 1.5f;
    if (q < 0.5f) q = 0.5f;
    if (q > 2.0f) q = 2.0f;
    return q;
}

// Called from the compositor once per frame with the physical texture size. Commits only on
// a real change (>16 px on either axis), because a resize tears down and rebuilds every
// wrapped target and doing it per frame is the two-phase-entry trap ninety times a second.
// A HARNESS OVERRIDE for the physical size (R5). The visionOS SIMULATOR's drawable is 16:9;
// a real Vision Pro view is nearly square, and the eye targets are sized from it. That one
// difference makes the whole class of "the 2D is laid out for the wrong shape" defect — the
// square panel, and then the square HUD — INVISIBLE on a simulator: the sim's eye target is
// already widescreen, so there is nothing for a widescreen sub-rect to differ from. Injecting
// the headset's shape at the compositor's own entry point is what lets a sim run assert those
// fixes at all. Latched, because the compositor reports the real size every frame and would
// otherwise overwrite the injection immediately.
static atomic_int vr_phys_forceW, vr_phys_forceH;

void Q2_VR_ForcePhysicalSize(int w, int h)
{
    atomic_store(&vr_phys_forceW, w);
    atomic_store(&vr_phys_forceH, h);
    if (w > 0 && h > 0) Q2_VR_ReportPhysicalSize(w, h);
}

// =====================================================================================
// [R19] THE MEMORY BUDGET BEHIND VR RENDER QUALITY
// =====================================================================================
// Reported on 1.0.11.22: "I had a crash while increasing the render quality." No .ips reached
// the device's crash store and no jetsam snapshot named us — which is not the absence of
// evidence it looks like, it is the SIGNATURE of a jetsam kill: the process is gone before
// any handler runs, so it writes nothing, and the same silence killed 1.0.11.17 on a map
// load (which is why Q2_VR_MemStats exists at all).
//
// The arithmetic says it plainly. A Vision Pro view's physical colour texture is about
// 1920x1824 per eye, so at VR Render Quality `q` an eye target is (1920q x 1824q). The port
// holds, per eye pixel, four bytes for each of:
//
//     2 eyes x N ring slots   colour  (RGBA8)
//     2 eyes x N ring slots   depth   (Depth32Float)
//     1       x N ring slots   UI     (RGBA8)
//     6                        compositor privates (privColor 2, privDepth 2, sharpTex 2)
//
// = (5N + 6) surfaces. At the shipped N = 5 that is 124 bytes per eye pixel:
//
//     1.00x  1920x1824  = 3.50 MP  ->   434 MB
//     1.25x  2400x2280  = 5.47 MP  ->   678 MB
//     1.50x  2880x2736  = 7.88 MP  ->   977 MB   (R10 measured ~914 MB on device)
//     1.75x  3360x3192  = 10.7 MP  ->  1330 MB
//     2.00x  3840x3648  = 14.0 MP  ->  1737 MB
//
// and the TRANSIENT during the step is higher again, because the old generation's published
// set is still retained for half a second while the new ring is allocated. Nothing in the
// port ever checked any of this against the limit the OS actually kills over.
//
// So it is checked here, against the live reading rather than against a number written into
// a comment: os_proc_available_memory (through Q2_VR_MemStats) is the headroom this process
// has left, and cur + avail is its jetsam limit. Two levers, spent in this order:
//
//   1. RING DEPTH — 5 -> 4 -> 3. Invisible to the player (the reader gate is what makes a
//      shallow ring correct; five slots were margin, not correctness), and each slot removed
//      is 5 eye-sized surfaces.
//   2. THE EXTENT — only when even a 3-deep ring will not fit. Visible, so it is last, and
//      it is logged.
//
// On the simulator avail reads 0 (no jetsam limit to measure against) and the budget is
// skipped entirely — a sim run must exercise the same sizes a device run does.
#define VR_RING_MAX      5
#define VR_MEM_MARGIN_MB 192.0     // headroom left for the engine's own churn (map loads)
#define VR_MEM_TRANSIENT 1.25      // the old generation's retained publish set, overlapping

extern void VID_iOS_XR3_SetRingDepth(int n);

// [R20] THE MSAA SURFACES, in the SAME budget. They are two surfaces, not two per eye and
// not two per ring slot — the engine renders eyes and ring slots sequentially, so xr3_glue
// shares one multisampled colour + depth pair across all of them — but at 4x they are eight
// bytes per eye pixel per sample, which is 130 MB at 2048x1984 and 400 MB at 1.75x quality.
// A memory lever the budget could not see is a memory lever that gets the process jetsammed,
// which is the whole reason vr_plan_budget exists.
//
// [R22] BUDGET FROM WHAT THE BACKEND ALLOCATES, NOT FROM WHAT THE ROW ASKS FOR. GLES lets
// glRenderbufferStorageMultisample round the sample count UP, and ANGLE-Metal does: Metal
// reports no 2-sample support, so a "2x" request comes back as a 4-sample renderbuffer
// (xr3_ms_ensure logs the backend counts and now publishes the larger of them). Budgeting the
// requested 2 halved the 2x row's cost — 140 MB claimed against 279 MB really allocated at
// 1.5x quality — and a memory lever the budget mis-reads by 2x is the same defect the whole
// of vr_plan_budget exists to prevent. Before the first allocation there is nothing to read
// back, so 2 is planned as 4 up front; the backend's own number takes over once it is known
// and can only ever be >= what was asked for.
static double vr_msaa_bytes(int w, int h)
{
    int s = Q2_VR_MsaaWanted();
    if (s < 2) return 0.0;
    const int real = VID_iOS_XR3_MsaaBackendSamples();
    if (real > 0) s = real;         // the backend's own count, once the FBO exists, is the truth
    else if (s < 4) s = 4;          // before that: this backend rounds 2 up to 4, assume it
    return (double)w * (double)h * (double)s * 8.0;   // RGBA8 + Depth32Float, multisampled
}

static double vr_target_bytes(int w, int h, int ring)
{
    return (double)w * (double)h * 4.0 * (double)(5 * ring + 6) + vr_msaa_bytes(w, h);
}

static float vr_mem_avail_mb(void)
{
    float cur = 0, peak = 0, avail = 0;
    Q2_VR_MemStats(&cur, &peak, &avail);
    return avail;
}

// Returns the ring depth to use, and shrinks *pw/*ph in place if even the shallowest ring
// does not fit. Never grows the request.
static int vr_plan_budget(int *pw, int *ph, char *why, int whysz)
{
    if (why && whysz > 0) why[0] = 0;
    float cur = 0, peak = 0, avail = 0;
    Q2_VR_MemStats(&cur, &peak, &avail);
    if (avail <= 0.0f) {
        if (why && whysz > 0) Q_snprintf(why, (size_t)whysz, "budget=off(no jetsam limit)");
        return VR_RING_MAX;
    }
    const double MB = 1024.0 * 1024.0;
    const double limit = ((double)cur + (double)avail) * MB;
    // Everything in the footprint that is NOT eye targets: engine, ANGLE, textures, audio.
    // Derived from the CURRENT committed size rather than guessed, so it tracks a map load.
    const int cw = atomic_load(&vr_committed_w), ch = atomic_load(&vr_committed_h);
    double other = (double)cur * MB;
    if (cw > 0 && ch > 0) other -= vr_target_bytes(cw, ch, VID_iOS_XR3_RingDepth());
    if (other < 0.0) other = 0.0;
    const double room = limit - other - VR_MEM_MARGIN_MB * MB;
    for (int ring = VR_RING_MAX; ring >= 3; ring--) {
        if (vr_target_bytes(*pw, *ph, ring) * VR_MEM_TRANSIENT <= room) {
            if (why && whysz > 0)
                Q_snprintf(why, (size_t)whysz, "budget=fit ring=%d room=%.0fMB", ring, room / MB);
            return ring;
        }
    }
    // Still over at ring 3: shrink the extent to fit, preserving aspect, and say so.
    const int ring = 3;
    const double need = vr_target_bytes(*pw, *ph, ring) * VR_MEM_TRANSIENT;
    double scale = (need > 0.0 && room > 0.0) ? sqrt(room / need) : 0.5;
    if (scale > 1.0) scale = 1.0;
    if (scale < 0.4) scale = 0.4;       // never below 40% of the request: a floor, not a cliff
    int nw = ((int)((double)*pw * scale) + 7) & ~7;
    int nh = ((int)((double)*ph * scale) + 7) & ~7;
    if (nw < 8) nw = 8;
    if (nh < 8) nh = 8;
    if (why && whysz > 0)
        Q_snprintf(why, (size_t)whysz, "budget=CLAMPED ring=3 room=%.0fMB %dx%d->%dx%d",
                   room / MB, *pw, *ph, nw, nh);
    *pw = nw; *ph = nh;
    return ring;
}

// [R19] AND THE OTHER HALF: A DRAG IS ONE RESIZE, NOT NINETY.
//
// Nothing in the settings sheet pushes vr_quality anywhere — this function READS it from
// NSUserDefaults, and the compositor calls this function once per compositor frame (120 Hz,
// and under R17's free-run it keeps calling it while the engine is paced at half that). So
// dragging the VR Render Quality slider from 1.5x to 2.0x commits a new size every time the
// value moves more than ~0.009x (16 px on a 1824 px axis) and the engine tears down and
// rebuilds the entire ring at the top of every frame for the whole duration of the drag.
// Each of those replacements leaves its published set retained for half a second
// (xr3_retire), so a one-second drag can hold a dozen generations of eye targets at once.
// The 3D panel's Render Resolution row never had this problem: it resyncs on slider RELEASE
// (`resync: true` in VisionShell's row()), which is exactly the behaviour this restores for
// VR — in the C layer, so `q2vrset vr_quality` in a stress loop gets it too.
#define VR_RESIZE_SETTLE_MS 300
static _Atomic int      vr_req_w, vr_req_h;      // the settling size (post-budget)
static _Atomic int      vr_raw_w, vr_raw_h;      // the last RAW request already answered
static _Atomic uint64_t vr_req_since_ms;

void Q2_VR_ReportPhysicalSize(int w, int h)
{
    int fw = atomic_load(&vr_phys_forceW), fh = atomic_load(&vr_phys_forceH);
    if (fw > 0 && fh > 0) { w = fw; h = fh; }
    if (w <= 0 || h <= 0) return;
    atomic_store(&vr_phys_w, w);
    atomic_store(&vr_phys_h, h);
    Q2_VR_SetDrawableReady(1);

    float s = vr_render_scale();
    int tw = (int)lroundf(w * s), th = (int)lroundf(h * s);
    // Cap the larger axis at 8192 preserving aspect. The clamp on the scale is not the
    // guard that matters: a donor hit a Metal texture-validation abort because a legal
    // scale times a large drawable exceeded the texture limit. The EXTENT is the invariant.
    int mx = tw > th ? tw : th;
    if (mx > 8192) { tw = (int)((float)tw * 8192.0f / mx); th = (int)((float)th * 8192.0f / mx); }
    tw = (tw + 7) & ~7; th = (th + 7) & ~7;

    // [R19] THE RAW-REQUEST LATCH, and it is doing three jobs at once.
    //  * Cost: Q2_VR_MemStats is a mach task_info syscall, and this function runs on the
    //    compositor thread once per frame at 120 Hz. It must not run per frame.
    //  * Stability: the budget's answer moves with the live footprint. Re-planning an
    //    ALREADY-SATISFIED request every frame is how a clamp oscillates — clamp down, the
    //    footprint falls because the targets are smaller, the budget now says the big size
    //    fits, resize up, clamp down again, each cycle a full ring rebuild. (`other` below
    //    subtracts the current targets precisely so the answer does not depend on the size
    //    being measured; this latch is the belt to that braces.)
    //  * Truth: the thing the player changed is the RAW request. Once a raw request has been
    //    answered, the answer stands until they change it again.
    int rawW = tw, rawH = th;
    if (abs(rawW - atomic_load(&vr_raw_w)) <= 16 && abs(rawH - atomic_load(&vr_raw_h)) <= 16 &&
        atomic_load(&vr_committed_w) > 0)
        return;

    // The budget, before the settle: the clamped size is what has to be stable, or a
    // request that the budget rounds down would never look settled.
    char why[96];
    int ring = vr_plan_budget(&tw, &th, why, sizeof why);

    int cw = atomic_load(&vr_committed_w), ch = atomic_load(&vr_committed_h);
    if (abs(tw - cw) <= 16 && abs(th - ch) <= 16) {
        // Already at the size this request resolves to. Latch the raw request so the plan is
        // not recomputed every frame; the ring depth is deliberately NOT re-applied here,
        // because changing it means replacing the ring and the ring is only ever replaced by
        // a size change (VID_iOS_XR3_ResizeEyes_Now, which latches whatever depth is wanted).
        atomic_store(&vr_req_w, tw); atomic_store(&vr_req_h, th);
        atomic_store(&vr_raw_w, rawW); atomic_store(&vr_raw_h, rawH);
        return;
    }
    // [R19] THE SETTLE. Skipped when nothing is committed yet: two-phase VR entry is waiting
    // on the first size and a 300 ms hold there would be a 300 ms black entry for no gain.
    if (cw > 0 && ch > 0) {
        const uint64_t now = clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000000ull;
        int rw = atomic_load(&vr_req_w), rh = atomic_load(&vr_req_h);
        if (abs(tw - rw) > 16 || abs(th - rh) > 16) {
            atomic_store(&vr_req_w, tw);
            atomic_store(&vr_req_h, th);
            atomic_store(&vr_req_since_ms, now);
            return;                       // first sighting of this size: let the drag finish
        }
        if (now - atomic_load(&vr_req_since_ms) < VR_RESIZE_SETTLE_MS) return;
    }
    atomic_store(&vr_committed_w, tw);
    atomic_store(&vr_committed_h, th);
    atomic_store(&vr_req_w, tw);
    atomic_store(&vr_req_h, th);
    atomic_store(&vr_raw_w, rawW);
    atomic_store(&vr_raw_h, rawH);
    VID_iOS_XR3_SetRingDepth(ring);
    char mem[96] = "";
    Q2_VR_MemLine(mem, sizeof mem);
    char line[320];
    Q_snprintf(line, sizeof(line),
               "VRSIZE phys=%dx%d rscale=%.2f target=%dx%d ring=%d msaa=%d est=%.0fMB %s %s "
               "source=physical_colour_texture",
               w, h, s, tw, th, ring, Q2_VR_MsaaWanted(),
               vr_target_bytes(tw, th, ring) / (1024.0 * 1024.0), why, mem);
    Q2_VR_BlackBoxPin("eyesize", line);
    Q2_VR_Log(line);
    // The resize itself is GL work and belongs to whoever holds the context, so it is
    // requested here and applied at the top of the engine frame (below).
}

// =====================================================================================
// The entry watch (R23) — naming the state a black VR entry is in
// =====================================================================================
// Reported on 1.0.11.26: "sometimes when entering VR mode, it'll be a black screen but with
// audio. I have to exit VR then re-enter, then it's fine." Audio means the engine thread is
// alive and stepping the sim, so the frame that reaches the eyes is the half that failed —
// and intermittent-per-entry is a RACE (D-VR-R16). The R16 lesson is that the first
// instrument for a race is a COUNTER ON EVERY OWNERSHIP TRANSITION, not a renderer diff, so
// this section counts the five things that have to line up for a VR entry to show a picture
// and prints ONE line, 2 s in, naming which of them did not.
//
// The five states a black entry can be in, and the field that proves each:
//   no_comp     the compositor loop is not presenting at all (layer paused, or the space
//               opened onto a renderer that never ran)              -> comp=0
//   no_pair     the engine renders but nothing is PUBLISHED: the ring was never allocated,
//               or every completion block refused its publish        -> pubs=0 (refused=N)
//   not_adopted pairs publish but the compositor never has one in hand — a generation the
//               shell is not holding, or its pipelines never built   -> adopt=0 with pubs>0
//   no_anchor   pairs are adopted and drawn, and the drawable is submitted with NO device
//               anchor: ARKit never handed one over, so there is nothing for the system to
//               reproject against and the eyes stay black            -> anchor=0
//   mainticks   the R16 race: the 2D display link is driving the engine beside the VR
//               thread                                              -> mainticks>0
// A sixth verdict, `ok`, means all five are healthy and a black picture is downstream of
// everything this side can see (the shader, the source pixels) — which is a different
// investigation and this line says so rather than staying silent.
//
// Every counter is per SESSION: armed by Q2_VR_SetRendezvousActive(1) at entry, and read by
// the engine thread. The compositor writes them (relaxed atomics, one store per frame, no
// logging on that thread); the ENGINE prints, because Q2_VR_Log is the engine's own voice
// and this line has to land in console.log and the black box where q2vrbb can echo it.

static _Atomic uint64_t vr_entry_t0_ns;        // 0 = not armed (no session)
static atomic_uint  vr_entry_comp;             // compositor frames since entry
static atomic_uint  vr_entry_adopt;            // ... holding a published pair
static atomic_uint  vr_entry_anchor;           // ... that submitted a device anchor
static atomic_int   vr_entry_shell_gen = -1;   // eye generation the SHELL is holding
static atomic_int   vr_entry_pipe_ok;          // the compositor's pipelines built
static atomic_int   vr_entry_ar_state = -1;    // WorldTrackingProvider state (Swift ord)
static atomic_uint  vr_entry_ar_err;           // tracking runs that threw
static atomic_uint  vr_entry_heals;            // self-heals attempted this session
static atomic_int   vr_entry_curtain;          // the 2D window's curtain, as an outcome
static atomic_int   vr_entry_reports;          // VRENTRY lines printed this session
static char         vr_entry_heal_what[24];    // last heal reason; compositor writes, engine reads

// [R23] THE FAULT INJECTOR (`q2vrfaultentry <mask>`), because the black entry did not
// reproduce in 42 simulator entries and a self-heal nobody has ever seen fire is a claim,
// not a repair. Bit 1 tells the compositor to report "no device anchor" and bit 2 "no pair
// adopted", which is exactly what the two failing states look like TO THE DETECTOR — so the
// verdict, the heal and the recovery line can all be driven on demand. It injects into the
// detector and not into the renderer, and the artifact says so: what it proves is that
// `no_anchor` is diagnosed, that the heal runs, and that world tracking comes back up after
// it; the black PICTURE itself is a headset symptom this simulator cannot composite.
// Cleared by the heal, so the second VRENTRY line reads the recovery rather than the fault.
static atomic_int vr_entry_fault;
void Q2_VR_SetEntryFault(int mask) { atomic_store(&vr_entry_fault, mask); }
int  Q2_VR_EntryFault(void) { return atomic_load(&vr_entry_fault); }

void Q2_VR_ArmEntryWatch(int on)
{
    if (on) {
        atomic_store(&vr_entry_comp, 0);
        atomic_store(&vr_entry_adopt, 0);
        atomic_store(&vr_entry_anchor, 0);
        atomic_store(&vr_entry_shell_gen, -1);
        atomic_store(&vr_entry_pipe_ok, 0);
        atomic_store(&vr_entry_ar_state, -1);
        atomic_store(&vr_entry_ar_err, 0);
        atomic_store(&vr_entry_heals, 0);
        atomic_store(&vr_entry_reports, 0);
        vr_entry_heal_what[0] = 0;
        atomic_store(&vr_entry_t0_ns, vr_now_ns());
    } else {
        atomic_store(&vr_entry_t0_ns, 0);
    }
}

// Compositor thread, once per frame, from the ONE place that knows all four answers.
void Q2_VR_NoteCompositorFrame(int adopted, int anchored, int shellGen, int pipelineOk)
{
    atomic_fetch_add(&vr_entry_comp, 1);
    if (adopted)  atomic_fetch_add(&vr_entry_adopt, 1);
    if (anchored) atomic_fetch_add(&vr_entry_anchor, 1);
    atomic_store(&vr_entry_shell_gen, shellGen);
    atomic_store(&vr_entry_pipe_ok, pipelineOk ? 1 : 0);
}

// Compositor thread. `state` is the WorldTrackingProvider's own state ordinal (0 initialized,
// 1 running, 2 paused, 3 stopped, -1 unknown); `errorBump` counts a run that threw.
void Q2_VR_NoteArkit(int state, int errorBump)
{
    if (state >= -1) atomic_store(&vr_entry_ar_state, state);
    if (errorBump) atomic_fetch_add(&vr_entry_ar_err, 1);
}

// Compositor thread, when the self-heal fires. `what` is short and console-safe.
void Q2_VR_NoteEntryHeal(const char *what)
{
    atomic_fetch_add(&vr_entry_heals, 1);
    if (what) Q_strlcpy(vr_entry_heal_what, what, sizeof vr_entry_heal_what);
    atomic_store(&vr_entry_fault, 0);   // an injected fault ends at the repair it provoked
    // A heal is worth a second VRENTRY line: the first said what was wrong, the next says
    // whether the repair took. Re-arm the reporter without touching the counters — the
    // totals are what make "it recovered" visible.
    if (atomic_load(&vr_entry_reports) > 1) atomic_store(&vr_entry_reports, 1);
}

int Q2_VR_EntryHealCount(void) { return (int)atomic_load(&vr_entry_heals); }
void Q2_VR_NoteCurtain(int up) { atomic_store(&vr_entry_curtain, up ? 1 : 0); }
int  Q2_VR_AppBackgrounded(void) { return atomic_load(&vr_app_backgrounded); }

// Engine thread, at the end of every VR frame. Prints at 2 s (every entry, healthy or not:
// a line that only appears when something is wrong has no baseline to be read against) and
// again at 6 s when the 2 s verdict was not `ok` or a heal has fired since.
void Q2_VR_EntryWatch(void)
{
    const uint64_t t0 = atomic_load(&vr_entry_t0_ns);
    if (!t0) return;
    const int reports = atomic_load(&vr_entry_reports);
    if (reports > 1) return;
    const uint64_t ms = (vr_now_ns() - t0) / 1000000ull;
    if (reports == 0 && ms < 2000) return;
    if (reports == 1 && ms < 6000) return;

    const unsigned comp   = atomic_load(&vr_entry_comp);
    const unsigned adopt  = atomic_load(&vr_entry_adopt);
    const unsigned anchor = atomic_load(&vr_entry_anchor);
    const unsigned heals  = atomic_load(&vr_entry_heals);
    const int      pubs   = VID_iOS_XR3_FramesRendered();
    const unsigned ticks  = Q2_VR_MainTicksInVR();

    const char *state = "ok";
    if (ticks > 0)          state = "mainticks";
    else if (comp == 0)     state = "no_comp";
    else if (pubs == 0)     state = "no_pair";
    else if (adopt == 0)    state = "not_adopted";
    else if (anchor == 0)   state = "no_anchor";
    // A heal that took leaves every counter healthy, so a verdict read at the instant would
    // say `ok` about an entry that WAS black for a second and repaired itself. `healed` is
    // that entry, and it is the one the next report needs named: the `heal=` field says
    // which repair, and `adopt`/`anchor` trailing `comp` says how long it was dark.
    else if (heals > 0)     state = "healed";

    int ew = 0, eh = 0;
    VID_iOS_XR3_EyeSize(&ew, &eh);
    char line[416];
    Q_snprintf(line, sizeof line,
               "VRENTRY t=%llums state=%s comp=%u adopt=%u anchor=%u pubs=%d ar=%d/%u "
               "gen=eng%d/shell%d inflight=%d refused=%d mainticks=%u clsactive=%d sync=%s "
               "present=%s eye=%dx%d committed=%dx%d phys=%dx%d pipe=%d curtain=%d heal=%u/%s "
               "fault=%d",
               (unsigned long long)ms, state, comp, adopt, anchor, pubs,
               atomic_load(&vr_entry_ar_state), atomic_load(&vr_entry_ar_err),
               VID_iOS_XR3_EyeGeneration(), atomic_load(&vr_entry_shell_gen),
               VID_iOS_XR3_InFlight(), VID_iOS_XR3_PubRefused(), ticks,
               vr_sync_active, vr_sync_mode,
               Q2_VR_PresentIsWorld() ? "world" : Q2_VR_PresentReason(),
               ew, eh, atomic_load(&vr_committed_w), atomic_load(&vr_committed_h),
               atomic_load(&vr_phys_w), atomic_load(&vr_phys_h),
               atomic_load(&vr_entry_pipe_ok), atomic_load(&vr_entry_curtain),
               heals, vr_entry_heal_what[0] ? vr_entry_heal_what : "none",
               atomic_load(&vr_entry_fault));
    Q2_VR_BlackBoxPin("entry", line);
    Q2_VR_Log(line);
    if (reports == 0 && !strcmp(state, "ok") && heals == 0)
        atomic_store(&vr_entry_reports, 2);   // healthy: one line is the whole story
    else
        atomic_store(&vr_entry_reports, reports + 1);
}

// =====================================================================================
// Contract dump (frame 0)
// =====================================================================================
// STRUCTURAL fields are diffed on every subsequent dump — a change in any of them means the
// drawable contract moved under us and every assumption downstream is suspect. VOLATILE
// fields are never diffed; they change every frame by design and diffing them turns the
// instrument into noise.
void Q2_VR_DumpContract(const char *structural, const char *volatileLine)
{
    if (structural) {
        Q2_VR_BlackBoxPin("contract", structural);
        Q2_VR_Log(structural);
    }
    if (volatileLine) Q2_VR_Log(volatileLine);
    Q2_VR_BlackBoxFlush(1);
}

// =====================================================================================
// The engine frame, in VR
// =====================================================================================

static void vr_engine_frame(void)
{
    q2_vr_pose_t pose;
    // [R17] `q2vrfreeze 1`: the engine renders NOTHING and publishes nothing; the compositor
    // keeps presenting the last pair against the anchor that pair was rendered with, so the
    // only thing that can move the picture is the compositor's own reprojection. If the
    // flicker survives a freeze it is downstream of every engine frame ever rendered; if it
    // stops, it is in what the engine produces or in the cadence it produces it at. The
    // sleep is short so the stop flag is still honoured within a frame.
    if (Q2_VR_Freeze()) {
        // The console reaches the engine thread THROUGH this drain in VR (ios_remote_console
        // queues, this thread runs): without it a freeze is a one-way door — `q2vrfreeze 0`
        // itself would never execute. Found by the R17 targeted check on the simulator.
        Q2_iOS_QueueDrain();
        Q2_VR_Tick();
        usleep(8000);
        return;
    }
    bool fresh = Q2_VR_EngineAcquire(&pose);
    (void)fresh;   // a stale pair is re-rendered on purpose, not an error
    // [R21] The frame clock starts AFTER the acquire: everything below is work, the wait
    // above is the divisor doing its job, and mixing the two would make a perfectly paced
    // engine look like one with no headroom.
    const uint64_t vr_frame_t0 = vr_now_ns();
    // The sim cadence follows the layer rate (see THE PACING CONTROLLER). Called here rather
    // than at thread start because the layer period is not known until the compositor has
    // measured it, and it CHANGES — the same headset has presented at 60 and at 120.
    vr_pace_cvars_apply();
    vr_pace_probe_sync();
    vr_frame = pose;
    int haveTracked = pose.valid || Q2_VR_PoseOverride(NULL, NULL, NULL, NULL, NULL);
    atomic_store(&vr_have_pose, haveTracked);
    Q2_VR_SetPoseValid(haveTracked);
    // The synthetic pose override is folded into the acquired pair HERE, not only at the
    // per-eye site, so that everything downstream — the aim source, the body-yaw seed, the
    // dumps — sees ONE effective head. An override that only reached the renderer would make
    // a simulator run prove the renderer while leaving the input path untested.
    {
        float oy, op;
        if (Q2_VR_PoseOverride(&oy, &op, NULL, NULL, NULL)) {
            vr_frame.headYawDeg = oy;
            vr_frame.headPitchDeg = op;
            vr_frame.headRollDeg = 0.0f;
        }
    }
    vr_last_headyaw = vr_frame.headYawDeg;
    vr_last_headpitch = vr_frame.headPitchDeg;

    // 1. Everything a foreign thread asked for, in order, before any engine state is read.
    Q2_iOS_QueueDrain();

    // 2. A committed eye size is applied HERE, on the thread that owns the GL context.
    int cw = atomic_load(&vr_committed_w), ch = atomic_load(&vr_committed_h);
    if (cw > 0 && ch > 0) {
        int ew = 0, eh = 0;
        VID_iOS_XR3_EyeSize(&ew, &eh);
        if (abs(ew - cw) > 16 || abs(eh - ch) > 16)
            VID_iOS_XR3_SetVREyeSize(cw, ch);
    }

    // The near plane is set for EVERY VR frame, not just world frames: the composite reads
    // it on every frame it draws, and a panel frame that left it at zero handed the shader
    // a divide-by-nothing. Identity, not intent — the dump reports the same two numbers the
    // composite is actually given.
    q2vr.znear = (vr_frame.znear_m > 0.01f ? vr_frame.znear_m : 0.1f) * Q2_VR_WorldScale();

    // The settings section, applied from the store on a bumped generation and nothing else
    // (see Q2_VR_ApplySettings). One integer read per frame; the sheet is a MainActor view
    // and every direct call from it would otherwise have to cross the producer funnel.
    Q2_VR_ApplySettings(0);

    Q2_iOS_AudioTick();
    Q2_VR_NotePresent();

    int world = Q2_VR_PresentIsWorld();

    // THE PANEL SHAPE (R3 — "the 2D panel in VR is a square"). A VR eye target is nearly
    // square because a Vision Pro view is; the engine lays its whole 2D stream out for
    // `r_config`, so with r_config at the eye size the menus, the console and a demo were
    // composed for a square screen and looked like one. A world frame must keep the eye
    // shape — the projection has to match the drawable — so the shape is switched at the
    // ARBITRATION TRANSITION, which is the only moment either answer changes. The eye
    // textures are NOT re-created: the engine renders into a 16:9 sub-rect of the same
    // texture and the compositor samples exactly that sub-rect on a 16:9 quad, so the cost of
    // a menu opening is R_ModeChanged's three assignments and not six Metal allocations.
    // Called every frame and idempotent inside, rather than edge-detected here: the shape is
    // state that has to be right after an exit and a re-entry too, and an edge detector with
    // its own memory is a second source of truth for it.
    VID_iOS_XR3_SetPanelShape(!world);

    // 3. The player's own state — body yaw, turning, aim, movement direction, standing
    // height — computed ONCE per host frame, after the queue drain (so an injected stick set
    // this frame is the stick this frame uses) and before Qcommon_Frame (so what it writes is
    // what CL_UpdateCmd reads). Per eye would turn the body twice per frame.
    Q2_VR_InputFrame(vr_frame.headYawDeg, vr_frame.headPitchDeg, world, haveTracked);

    if (world) {
        // Per-eye world frames. The eye pair MUST be same-frame: with cl_async 0 and
        // cl_maxfps 62 against a 90 Hz cadence, CL_Frame early-returns without rendering on
        // a large fraction of ticks, and the shipped 3D path then publishes a stale left eye
        // beside a fresh right one. Harmless on a flat panel, a stereo mismatch in VR. So
        // BOTH eyes are rendered explicitly here, from the same sim state.
        //
        // [R8 mechanism 2] THE RENDER COUNT IS NOW CONSTANT. It used to be two or three:
        // `Qcommon_Frame`'s own `SCR_UpdateScreen` drew whenever `cl_maxfps` did not throttle
        // the tick, then the guard below drew eye 0 when it had, then eye 1 always. So eye 0
        // was sometimes the FIRST `R_RenderFrame` of the host frame and sometimes the SECOND,
        // alternating at the throttle beat, while eye 1 was always the LAST — and
        // `R_RenderFrame` is not idempotent for dynamic lighting. That is the flicker that was
        // reported, worse in the right eye, and the wall lit bright on one half. Overlay 0030's
        // `V_SuppressFrameRender` removes the inner draw (the rest of the frame — sound,
        // input, prediction — still runs), so the sequence is now exactly: sim step, eye 0,
        // eye 1, every host frame. Overlay 0031 then makes the eye-1 render reuse eye 0's
        // dlight stamp instead of consuming it. `V_FrameRendered` is still cleared per host
        // frame so the flag keeps meaning "this frame", for the dumps and for xr_boot's
        // (untouched) 3D-panel path.
        // Eye 0 stays bound across the step even though the step no longer draws: a few
        // engine paths (map load progress, `CL_PrepRefresh`) call `SCR_UpdateScreen` directly
        // and are NOT covered by the suppression, and they must land on a valid target. The
        // real eye-0 render below re-binds and re-clears it, so this costs one clear.
        vr_apply_eye(0);
        VID_iOS_XR3_BeginEye(0, 0.0f, 1.0f);
        V_SuppressFrameRender(true);
        V_FrameRendered(true);              // clear the flag before the step
        Qcommon_Frame();
        V_SuppressFrameRender(false);
        vr_apply_eye(0);
        VID_iOS_XR3_BeginEye(0, 0.0f, 1.0f);
        SCR_UpdateScreen();
        vr_apply_eye(1);
        VID_iOS_XR3_BeginEye(1, 0.0f, 1.0f);
        R_SetRepeatFrame(true);             // [0031] eye 1 repeats eye 0; do not re-consume
        SCR_UpdateScreen();
        R_SetRepeatFrame(false);
        // [R11] MODE 2 — THE 2D STREAM AS A PASS OF ITS OWN. Both eyes are finished; nothing
        // below binds an eye framebuffer again before EndFrame publishes them. `BeginUIPass`
        // makes the UI surface the pass's own target AND what UIEnd binds back to, so the
        // bracket opens and closes on the same framebuffer and neither eye's render pass is
        // interrupted by it. Overlay 0036's `ui_only` is what stops the third SCR_UpdateScreen
        // from rendering a third world (V_SuppressFrameRender guards CL_Frame's call site, not
        // this direct one), so the render count per host frame stays exactly two.
        //
        // The 2D stream is still drawn EXACTLY ONCE per host frame — modes 0 and 1 draw it
        // inside one eye, this draws it beside both — and the UI target's single clear is
        // still owned by the frame (BeginEye(0) resets the flag), so a mode change cannot
        // leave the HUD doubled or missing.
        if (Q2_VR_UIEye() == 2) {
            q2vr.ui_draw = 1;
            q2vr.ui_only = 1;
            VID_iOS_XR3_BeginUIPass();
            SCR_UpdateScreen();
            q2vr.ui_only = 0;
            q2vr.ui_draw = 0;
        }
        // BEFORE vr_clear_gate: the residual reads `q2vr.eye`, `q2vr.body_yaw` and the two
        // origins the frame just used, and the gate's clear is what ends their lifetime.
        vr_pose_residual_sample();
        vr_clear_gate();
        // [R8] The pose id travels WITH the pixels. EndFrame publishes this pair one to two
        // GPU frames from now; the compositor must submit THIS anchor when it does, not the
        // anchor of whatever frame it happens to be assembling then.
        VID_iOS_XR3_SetFramePoseId(pose.id);
        VID_iOS_XR3_EndFrame();
    } else {
        // Panel fallback: menus, console, loading, demos, cinematics and intermission render
        // to the existing mono panel, drawn world-locked INSIDE the VR space. The engine
        // path is the shipped 3D one, unchanged — this is the surface that is already
        // device-verified, and a menu is exactly the frame that must not be experimental.
        vr_clear_gate();
        atomic_fetch_add(&pace_panel, 1);
        // [R7a item 1] THE LEFT-EYE FLICKER. `BeginEye` CLEARS the eye target to opaque black
        // whenever the panel shape is on — which is every non-world frame — and eye 0's only
        // draw was `Qcommon_Frame()`, which early-returns without drawing on the frames
        // `CL_Frame` throttles. Eye 1 was drawn unconditionally by the `SCR_UpdateScreen()`
        // below. So a throttled panel frame published a BLACK LEFT EYE beside a FRESH RIGHT
        // EYE: one eye, darkening, in menus only, at the beat frequency between the engine
        // loop and `cl_maxfps`. Measured at about four times a second.
        //
        // BOTH EYES ARE NOW DRAWN EXPLICITLY, and the branch does not try to be clever about
        // it. The world branch six lines up repairs the same hazard CONDITIONALLY, gated on
        // `V_FrameRendered`, and copying that here was the first attempt and was wrong twice
        // over. `V_FrameRendered` means "R_RenderFrame ran" — a WORLD render — and a panel
        // frame has no world, so the predicate is false by construction and the guard fired on
        // 100 % of frames (measured: `panelmiss=424` of `panelframes=424`). It was therefore
        // both a meaningless counter and a conditional that was never a condition.
        //
        // The world branch needs the guess because re-rendering a world is expensive. This one
        // does not: a panel frame is 2D into a 16:9 sub-rect, and the worst case here is
        // redrawing a menu once. Deterministic beats clever on the surface that must not be
        // experimental — there is now no schedule of engine and compositor rates on which a
        // half-black pair can be published, rather than none we happened to sample.
        //
        //
        // [R8 mechanism 2] The third render is gone here too. Both eyes stayed unconditional —
        // that is what fixed the R7a black eye and it stays — but `Qcommon_Frame`'s own draw
        // was pure waste AND it was the first of three renders, which is how a DEMO playing on
        // the panel (a world render, on a panel frame) got the same left/right lighting split
        // as the world path. Suppressed; the two eye renders below are now the only two.
        // As in the world branch: eye 0 stays bound across the step for the direct
        // SCR_UpdateScreen call sites the suppression does not cover.
        VID_iOS_XR3_BeginEye(0, 0.0f, 1.0f);
        V_SuppressFrameRender(true);
        Qcommon_Frame();
        V_SuppressFrameRender(false);
        VID_iOS_XR3_BeginEye(0, 0.0f, 1.0f);
        SCR_UpdateScreen();
        VID_iOS_XR3_BeginEye(1, 0.0f, 1.0f);
        R_SetRepeatFrame(true);             // [0031] as above — the demo behind a panel frame
        SCR_UpdateScreen();
        R_SetRepeatFrame(false);
        VID_iOS_XR3_SetFramePoseId(pose.id);   // [R8] as above
        VID_iOS_XR3_EndFrame();
    }

    Q2_VR_Tick();
    Q2_VR_EngineRelease(pose.id);
    vr_pace_sample(vr_now_ns() - vr_frame_t0);
    vr_pace_second();
    // [R23] LAST, after everything this frame did is visible to it: the entry verdict.
    // It prints at most twice per session and reads counters the compositor already wrote.
    Q2_VR_EntryWatch();
}

static void *vr_engine_main(void *arg)
{
    (void)arg;
    pthread_setname_np("q2-engine");
    if (!VID_iOS_ANGLE_AcquireContext()) {
        Q2_VR_Log("ENGINE thread could not acquire the GL context - VR aborted");
        atomic_store(&vr_thread_running, 0);
        return NULL;
    }
    Q2_VR_Log("ENGINE thread running (owns the ANGLE context)");
    while (!atomic_load(&vr_thread_stop))
        @autoreleasepool { vr_engine_frame(); }
    // [R21] The pacing cvars go back BEFORE the context is released — this is the engine
    // thread, which is the only thread allowed to run a cvar `changed` callback here, and it
    // is about to stop existing. `cl_maxfps`/`cl_async`/`r_maxfps` carry no CVAR_ARCHIVE, so
    // a crash on this path costs a session's value and never the player's config.
    vr_pace_cvars_restore();
    VID_iOS_ANGLE_ReleaseContext();
    atomic_store(&vr_thread_running, 0);
    Q2_VR_Log("ENGINE thread stopped (context released)");
    return NULL;
}

// Main thread. The display link must already be paused and the context released.
int Q2_VR_StartEngineThread(void)
{
    if (atomic_load(&vr_thread_running)) return 1;
    atomic_store(&vr_thread_stop, 0);
    atomic_store(&vr_thread_running, 1);
    Q2_VR_SetRendezvousActive(1);
    VID_iOS_ANGLE_ReleaseContext();          // main gives the context up FIRST
    if (pthread_create(&vr_thread, NULL, vr_engine_main, NULL) != 0) {
        atomic_store(&vr_thread_running, 0);
        Q2_VR_SetRendezvousActive(0);
        VID_iOS_ANGLE_AcquireContext();      // roll back: main takes it straight back
        Q2_VR_Log("ENGINE thread create FAILED");
        return 0;
    }
    Q2_iOS_FunnelEnable(1, &vr_thread);
    atomic_store(&vr_owner, Q2VR_OWNER_VR);
    vr_pin_owner();
    return 1;
}

// A request plus a poll, never a join.
void Q2_VR_RequestEngineStop(void)
{
    atomic_store(&vr_thread_stop, 1);
    Q2_VR_SetRendezvousActive(0);            // unblock anything inside the rendezvous
}

// Main thread, after the poll says the thread is gone. Takes the context back and turns the
// funnel off so producers execute inline again.
void Q2_VR_FinishEngineStop(void)
{
    if (atomic_load(&vr_thread_running)) return;
    Q2_iOS_FunnelEnable(0, NULL);
    atomic_store(&vr_owner, Q2VR_OWNER_LINK);
    vr_clear_gate();
    // The per-frame gate keeps its sub-fields so the dumps can report the last VR frame, but
    // a LEAVING session must not leave function pointers behind: they point into a shell that
    // is no longer driving anything, and "inert because another flag is zero" is a weaker
    // guarantee than "not there".
    q2vr.aim_valid = 0;
    q2vr.move_rotate = 0;
    q2vr.ui_redirect = 0;
    q2vr.ui_draw = 0;
    q2vr.ui_begin = NULL;
    q2vr.ui_end = NULL;
    VID_iOS_ANGLE_AcquireContext();
    Q2_iOS_QueueDrain();                     // anything queued during the handover
    atomic_store(&vr_committed_w, 0);
    atomic_store(&vr_committed_h, 0);
    Q2_VR_SetDrawableReady(0);
    Q2_VR_SetPoseValid(0);
    vr_pin_owner();
}

// =====================================================================================
// Dump fields
// =====================================================================================
// APPENDED, never inserted: a field inserted mid-record lands on a junction that existing
// suite regexes span.

void Q2_VR_DumpEyeFields(char *out, int outsz)
{
    q2_vr_pose_t p;
    pthread_mutex_lock(&vr_mtx);
    p = vr_published;
    pthread_mutex_unlock(&vr_mtx);
    // Ask for the SAME numbers the composite is handed, including its fallbacks, rather
    // than reading the engine globals directly: a dump that reports what the shader would
    // use can be trusted about the shader, and one that reports an adjacent value cannot.
    float dznear = 2.0f, dzfar = 4096.0f;
    VID_iOS_XR3_DepthParams(&dznear, &dzfar);
    // IPD VERIFIED IN EYE SPACE, not player space (guide 12.5). Both eye offsets are
    // published in the SAME head-local basis, so the difference vector IS the right eye's
    // position expressed in the left eye's frame: assert it reads (+ipd, 0, 0). Comparing
    // world positions and asserting "+X" instead reads along Z once the head is yawed 90
    // degrees, and would false-alarm on the very first snap turn.
    float ipdRight = p.eye[1].ofsRight - p.eye[0].ofsRight;
    float ipdUp    = p.eye[1].ofsUp    - p.eye[0].ofsUp;
    float ipdFwd   = p.eye[1].ofsFwd   - p.eye[0].ofsFwd;
    // R3 — THE SIZING AUDIT, end to end in one record, because "resolution seems kinda low"
    // has to be answerable from the console on a device rather than from reasoning about
    // three files. physw/physh is the drawable's PHYSICAL per-view colour texture; rscale is
    // the multiplier actually applied (the VR Render Quality row); targetw/targeth is what
    // the shell committed; and EYENOW's own wpx/hpx is what the engine is actually rendering
    // into. `sizedfrom` is the identity field that matters: `physical` means the VR path
    // committed the size, `panelbudget` means the 3840x2160xxr_quality SCREEN formula leaked
    // into VR, which is a specific hazard the charter names and this is how it is caught.
    int cw = atomic_load(&vr_committed_w), ch = atomic_load(&vr_committed_h);
    int prw = 0, prh = 0;
    VID_iOS_XR3_PanelRect(&prw, &prh);
    Q_snprintf(out, outsz,
               " depth=%s physw=%d physh=%d rscale=%.2f targetw=%d targeth=%d sizedfrom=%s "
               "panelrect=%dx%d znear=%.1fu zfar=%.1fu "
               "worldscale=%.1fu_per_m depthfloor=%.6f "
               "tanL=%.3f tanR=%.3f tanU=%.3f tanD=%.3f headyaw=%.1fdeg headpitch=%.1fdeg "
               "ipdeye=(%.4f,%.4f,%.4f)m pubepoch=%d pubrefused=%d "
               // [R19] APPENDED, never inserted (the suite anchors on the junctions above).
               // These three answer "did the Render Quality step fit?" from one console
               // command: the ring depth the budget settled on, the eye-target bytes it
               // implies, and the headroom left before the OS kills the process. `avail=0`
               // is the simulator (no jetsam limit), not "no headroom".
               "ring=%d targetmb=%.0f availmb=%.0f "
               // [R20] APPENDED for the same reason the R19 three were: the suite anchors on
               // the junctions above. msaa= is what the eye FBO is ACTUALLY rendering at,
               // msaawant= what the row asks for, msaamax= what ANGLE will allow, and
               // msaaimplicit= whether GL_EXT_multisampled_render_to_texture is exported (it
               // is, but it resolves colour only, so the shipped path blits both).
               "msaa=%d msaawant=%d msaamax=%d msaaimplicit=%d",
               VID_iOS_XR3_VRDepthActive() ? "on" : "off",
               atomic_load(&vr_phys_w), atomic_load(&vr_phys_h), vr_render_scale(),
               cw, ch, (cw > 0 && ch > 0) ? "physical" : "panelbudget",
               prw, prh,
               dznear, dzfar, Q2_VR_WorldScale(), Q2_VR_DepthFloor(),
               p.eye[0].tanL, p.eye[0].tanR, p.eye[0].tanU, p.eye[0].tanD,
               vr_last_headyaw, vr_last_headpitch,
               ipdRight, ipdUp, ipdFwd,
               VID_iOS_XR3_PubEpoch(), VID_iOS_XR3_PubRefused(),
               VID_iOS_XR3_RingDepth(),
               (cw > 0 && ch > 0)
                   ? vr_target_bytes(cw, ch, VID_iOS_XR3_RingDepth()) / (1024.0 * 1024.0) : 0.0,
               vr_mem_avail_mb(),
               VID_iOS_XR3_MsaaActive(), Q2_VR_MsaaWanted(),
               VID_iOS_XR3_MsaaMax(), VID_iOS_XR3_MsaaImplicit());
}

void Q2_VR_DumpModeFields(char *out, int outsz)
{
    Q_snprintf(out, outsz, " owner=%s vrthread=%d posevalid=%d drawable=%d pubid=%llu rendered=%llu",
               atomic_load(&vr_owner) == Q2VR_OWNER_VR ? "vrthread" : "link",
               atomic_load(&vr_thread_running),
               atomic_load(&vr_have_pose),
               atomic_load(&vr_phys_w) > 0,
               (unsigned long long)vr_pub_id, (unsigned long long)vr_rendered_id);
}

#endif // Q2_XR_UI
