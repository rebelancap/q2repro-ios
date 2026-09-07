// q2_vr_dumps.m — the VR campaign's diagnostics: a black box, the `*NOW` dump family, and
// the synthetic-input boundary the simulator drives instead of real Sense hardware.
//
// Everything here is SHELL-side and registered post-Qcommon_Init alongside the existing
// console seams in ios_bridge.m — zero engine patches. It is compiled into every variant
// (iOS, visionOS 2D+3D) so the iPhone build's suites can assert the same machinery.
//
// Three rules the dump format enforces, each paid for on a sibling port:
//
//  1. FRESHNESS MUST BE PROVABLE. Every dump ends with a monotone `NOWSEQ n`, written
//     LAST, and assertions require it to ADVANCE. Counting matching lines does not work:
//     the black box rolls its tail and drops many lines at once, so the count can FALL
//     with the app perfectly healthy.
//  2. ONE LINE AT THE SINK, not by convention. A multi-line record once let a
//     `grep '^MOVENOW '` match a CONTINUATION line of another entry and read a stale value
//     as fresh. vr_emit() flattens at the emitter, so no caller can get this wrong.
//  3. LABEL THE UNITS. `pitch=12.0deg`, `x=3.5u`, `scale=34.0u_per_m`. An under-labelled
//     field produced a confident misreading and the wrong fix it implied.
//
// And one format constraint specific to this port: `Q2_XR3_Log` used to route through the
// engine's `echo` command, where a `;` splits the line into two commands and a `"` breaks
// parsing. The emitter below goes to Com_Printf directly and additionally SANITISES those
// characters, so no dump can ever be truncated by the transport.
//
// Appending a field? Append it at the END of the record. A field inserted mid-record lands
// on a junction that existing suite regexes span — that broke three suite cases twice on a
// sibling port. Grep the suites for the two field names either side of any insertion point.

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"
#include "system/system.h"        // Sys_Milliseconds
#include "client/keys.h"          // Key_GetDest, KEY_CONSOLE/KEY_MENU/KEY_MESSAGE
#include <mach/mach.h>            // task_info / TASK_VM_INFO — the footprint jetsam kills over
#include <mach/task_info.h>
#include <os/proc.h>              // os_proc_available_memory — the headroom left before it does

// ===================================================================================
// Black box
// ===================================================================================
// A PINNED region (facts that must survive any amount of churn: the contract dump, the
// mode, the eye geometry) plus a ROLLING tail (the last N events). Written to its own
// file, separate from the engine's console.log, so a log rotation cannot eat the evidence
// and so the file stays small enough to read over the wire. Files-app readable via
// UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace.
//
// Writes are COALESCED to ~1 Hz — an unthrottled rewrite per frame is itself a
// performance bug, and the previous port polluted its own measurements exactly that way.
// Q2_VR_BlackBoxFlush(1) bypasses the throttle for exit and for on-demand reads.

#define BB_PINNED_MAX   32
#define BB_ROLL_MAX     512
// EYENOW carries the whole depth-conversion contract (physical size, render scale,
// znear/zfar, world scale, the depth floor, four tangents and the eye-space IPD check), and
// BODYNOW now carries the whole alignment chain. A record truncated at the sink is a record
// whose last field silently reads as absent, which is worse than a long line — the suite
// anchors on fields at BOTH ends, so this grows with the records rather than the records
// being trimmed to fit it.
#define BB_LINE_MAX     640

static pthread_mutex_t bb_lock = PTHREAD_MUTEX_INITIALIZER;
static char bb_pin_key[BB_PINNED_MAX][32];
static char bb_pin_val[BB_PINNED_MAX][BB_LINE_MAX];
static int  bb_pin_count;
static char bb_roll[BB_ROLL_MAX][BB_LINE_MAX];
static int  bb_roll_head;      // next slot to write
static int  bb_roll_filled;
static bool bb_dirty;
static double bb_last_write;
static unsigned bb_dropped;    // rolling entries overwritten since the last flush

static NSString *bb_path(void)
{
    static NSString *cached;
    if (cached) return cached;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"profile/baseq2/logs"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    cached = [dir stringByAppendingPathComponent:@"vr-blackbox.log"];
    return cached;
}

// Flatten: a record must be ONE line at the sink, and must survive any transport that
// treats ';' or '"' as syntax. Done here so no caller can forget.
static void bb_sanitize(char *dst, size_t dstsz, const char *src)
{
    size_t j = 0;
    for (size_t i = 0; src[i] && j + 1 < dstsz; i++) {
        char c = src[i];
        if (c == '\n' || c == '\r' || c == '\t') c = ' ';
        else if (c == ';' || c == '"') c = '\'';
        dst[j++] = c;
    }
    dst[j] = 0;
}

void Q2_VR_BlackBoxPin(const char *key, const char *line)
{
    if (!key || !line) return;
    pthread_mutex_lock(&bb_lock);
    int slot = -1;
    for (int i = 0; i < bb_pin_count; i++)
        if (!strcmp(bb_pin_key[i], key)) { slot = i; break; }
    if (slot < 0 && bb_pin_count < BB_PINNED_MAX) slot = bb_pin_count++;
    if (slot >= 0) {
        Q_strlcpy(bb_pin_key[slot], key, sizeof(bb_pin_key[slot]));
        bb_sanitize(bb_pin_val[slot], BB_LINE_MAX, line);
        bb_dirty = true;
    }
    pthread_mutex_unlock(&bb_lock);
}

// [R17] Read a pinned line back by key (0 = no such pin). The compositor pins VRCLOCK and
// VRANCHOR once a second; `q2vrpace` echoes them so a headset session gets the whole pacing
// picture from ONE console command instead of a log fetch.
int Q2_VR_BlackBoxPinGet(const char *key, char *out, int outsz)
{
    if (!key || !out || outsz <= 0) return 0;
    out[0] = 0;
    int found = 0;
    pthread_mutex_lock(&bb_lock);
    for (int i = 0; i < bb_pin_count; i++)
        if (!strcmp(bb_pin_key[i], key)) { Q_strlcpy(out, bb_pin_val[i], outsz); found = 1; break; }
    pthread_mutex_unlock(&bb_lock);
    return found;
}

void Q2_VR_BlackBoxLog(const char *line)
{
    if (!line) return;
    pthread_mutex_lock(&bb_lock);
    if (bb_roll_filled >= BB_ROLL_MAX) bb_dropped++;
    bb_sanitize(bb_roll[bb_roll_head], BB_LINE_MAX, line);
    bb_roll_head = (bb_roll_head + 1) % BB_ROLL_MAX;
    if (bb_roll_filled < BB_ROLL_MAX) bb_roll_filled++;
    bb_dirty = true;
    pthread_mutex_unlock(&bb_lock);
}

void Q2_VR_BlackBoxFlush(int force)
{
    double now = Sys_Milliseconds() / 1000.0;
    pthread_mutex_lock(&bb_lock);
    if (!bb_dirty || (!force && now - bb_last_write < 1.0)) { pthread_mutex_unlock(&bb_lock); return; }
    bb_dirty = false;
    bb_last_write = now;
    int pinCount = bb_pin_count, rollCount = bb_roll_filled, head = bb_roll_head;
    unsigned dropped = bb_dropped;
    static char pinBuf[BB_PINNED_MAX][BB_LINE_MAX];
    static char pinKey[BB_PINNED_MAX][32];
    static char rollBuf[BB_ROLL_MAX][BB_LINE_MAX];
    memcpy(pinBuf, bb_pin_val, sizeof(pinBuf));
    memcpy(pinKey, bb_pin_key, sizeof(pinKey));
    memcpy(rollBuf, bb_roll, sizeof(rollBuf));
    pthread_mutex_unlock(&bb_lock);

    FILE *f = fopen(bb_path().UTF8String, "w");
    if (!f) return;
    fprintf(f, "=== q2repro VR black box === written_at=%.3fs rolling_dropped=%u\n", now, dropped);
    fprintf(f, "=== PINNED ===\n");
    for (int i = 0; i < pinCount; i++) fprintf(f, "%s\n", pinBuf[i]);
    fprintf(f, "=== ROLLING (oldest first, %d entries) ===\n", rollCount);
    for (int i = 0; i < rollCount; i++) {
        int idx = (head - rollCount + i + BB_ROLL_MAX * 2) % BB_ROLL_MAX;
        fprintf(f, "%s\n", rollBuf[idx]);
    }
    fclose(f);
    (void)pinKey;
}

// ===================================================================================
// Emitter
// ===================================================================================
// Two sinks: the engine console (so console.log and the tcp/8770 bridge both carry it)
// and the black box's rolling tail. Com_Printf directly — NOT the `echo` command, whose
// parser eats ';' and '"'. That bridge was the reason the dump format had a character
// blacklist at all.

static atomic_int vr_nowseq;

// ===================================================================================
// THE NOTIFY FIREWALL (R7b item 8a)
// ===================================================================================
// Second headset verdict: the haptic diagnostic "spams the console/notify" — it was
// landing in the transparent overlay the engine draws over the HUD, four lines of
// `HAPTIC #… -> played` sitting on top of the ammo count. The porting guide's §7 rule is
// blunt about it: the notify feed shows GAME-PRODUCED TEXT ONLY. Nothing the shell prints
// belongs there, and the haptic line was only the loudest offender — every *NOW dump, every
// VRSET echo and every one-per-second auto-pin went to the same place.
//
// The fix is NOT to stop printing. console.log, the tcp/8770 dev bridge and every suite
// assertion in `sim-verify-vr.sh` read these lines; silencing them would trade a cosmetic
// defect for a blind instrument. What they must not do is update `con.times[]`, which is the
// single thing that puts a console line into the overlay — and the engine already has the
// switch for it (`Con_SkipNotify`, used by the server's own game prints for exactly this
// reason). So every shell print goes through here, bracketed.
//
// Declared locally rather than by including client/client.h: the symbol is exported and
// stable, and that header drags the whole client state struct into six shell files that have
// no business seeing it.
extern void Con_SkipNotify(bool skip);

void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);
void Q2_VR_ConPrintf(const char *fmt, ...)
{
    char raw[BB_LINE_MAX];
    va_list ap;
    va_start(ap, fmt);
    Q_vsnprintf(raw, sizeof(raw), fmt, ap);
    va_end(ap);
    // Set/clear rather than save/restore: the engine's own users of this flag bracket a single
    // print the same way, nothing reads it across a call, and a saved value could only come
    // from a caller that is itself mid-bracket — which would mean a shell print nested inside
    // an engine one, and there is no such path.
    Con_SkipNotify(true);
    Com_Printf("%s", raw);
    Con_SkipNotify(false);
}

static void vr_emit(const char *fmt, ...)
{
    char raw[BB_LINE_MAX];
    va_list ap;
    va_start(ap, fmt);
    Q_vsnprintf(raw, sizeof(raw), fmt, ap);
    va_end(ap);
    char line[BB_LINE_MAX];
    bb_sanitize(line, sizeof(line), raw);
    Q2_VR_ConPrintf("%s\n", line);
    Q2_VR_BlackBoxLog(line);
}

// Written LAST in every dump. Assertions require it to ADVANCE between two reads;
// they must never count matching lines, because the rolling tail can drop many at once.
static void vr_nowseq_emit(void)
{
    int n = atomic_fetch_add(&vr_nowseq, 1) + 1;
    vr_emit("NOWSEQ %d", n);
}

// A log path that does NOT go through the `echo` bridge. Q2_XR3_Log routes here.
// Com_Printf walks the console buffer and the log file, so off the engine thread this
// goes through the producer funnel like every other engine-touching call. The black box
// itself is mutex-protected and could take a direct write, but splitting the two sinks
// would reorder the console against the box, which is exactly what makes a black box
// unreadable after the fact.
extern int  Q2_iOS_ShouldDefer(void);
extern void Q2_iOS_QueueLog(const char *msg);
void Q2_VR_LogNow(const char *msg)
{
    if (msg) vr_emit("%s", msg);
}
void Q2_VR_Log(const char *msg)
{
    if (!msg) return;
    if (Q2_iOS_ShouldDefer()) { Q2_iOS_QueueLog(msg); return; }
    vr_emit("%s", msg);
}

// ===================================================================================
// Mode + synthetic input state
// ===================================================================================
// The injection commands land at what will be the OUTPUT boundary of the Sense poll —
// the same place a real anchor will write — so when the real poll exists the transform
// chain and the input code under test are the real ones, not a parallel path. Nothing
// consumes these yet (R3 does); this round they are accepted, held, and echoed into the
// dumps, which is what makes the dumps assertable before any VR code exists.

static int vr_mode;   // 0 = 2D window, 1 = 3D panel, 2 = VR

// The alignment constant, console-settable so the device round can tune it without a
// settings row (charter D7: scale and height must not both be knobs). Frozen after tuning.
static float vr_worldscale = 34.0f;    // Quake units per metre
float Q2_VR_WorldScale(void) { return vr_worldscale; }

// The sky/far-plane depth floor. Converted sky depth is byte-identical to the compositor's
// "nothing rendered here", which it reprojects as BLACK — the donors lost five builds to
// this and NO simulator can reproduce it (there is no reprojection there). 1/8192 is about
// 800 m at a 0.1 m near plane. `q2vrdepthfloor 0` restores the bug exactly, which is the
// one-command causality proof on glass.
static float vr_depth_floor = 1.0f / 8192.0f;
float Q2_VR_DepthFloor(void) { return vr_depth_floor; }

// [R17] THE COMPOSITOR A/B SWITCHES. Every one of these is read by the compositor loop
// (VRShell.swift) or the engine frame (q2_vr_glue.m) on every frame, so a headset session
// can flip one WITHOUT re-entering VR — R16 established that every A/B that re-entered was a
// coin flip, so a switch that needs a re-entry is not an instrument. All atomics: written on
// the console thread, read on the compositor and engine threads.
//   freerun   1 = the compositor presents every layer frame and never waits on the engine
//                 (default). 0 = the R1 rendezvous: wait <=14 ms for the engine's frame.
//   depthmode 1 = per-pixel depth (default); 0 = the constant-2m fallback, which turns the
//                 compositor's positional reprojection off for the world.
//   anchormode 0 = submit the anchor the PAIR was rendered against (R8, default);
//              1 = submit the LIVE anchor of this compositor frame.
//   posediv   0 = auto (2 on a 120 Hz layer, else 1); N = the engine renders every Nth pose.
//   freeze    1 = the engine stops rendering; the compositor keeps presenting the last pair
//                 against its own anchor. Reprojection is then the ONLY thing moving.
//   mono      1 = both eyes render from eye 0's offset (tangents stay per view).
static atomic_int vr_ab_freerun = 1;
static atomic_int vr_ab_depthmode = 1;
static atomic_int vr_ab_anchormode = 0;
static atomic_int vr_ab_posediv = 0;
static atomic_int vr_ab_freeze = 0;
static atomic_int vr_ab_mono = 0;
static atomic_int vr_layer_period_us;      // the compositor's measured layer period
int  Q2_VR_FreeRun(void)      { return atomic_load(&vr_ab_freerun); }
int  Q2_VR_DepthMode(void)    { return atomic_load(&vr_ab_depthmode); }
int  Q2_VR_AnchorMode(void)   { return atomic_load(&vr_ab_anchormode); }
int  Q2_VR_Freeze(void)       { return atomic_load(&vr_ab_freeze); }
int  Q2_VR_Mono(void)         { return atomic_load(&vr_ab_mono); }
void Q2_VR_NoteLayerPeriod(double seconds)
{
    if (seconds > 0.0005 && seconds < 1.0) atomic_store(&vr_layer_period_us, (int)(seconds * 1e6));
}
// The divisor the engine ACTUALLY uses this frame: the override, or 2 when the layer runs
// faster than 100 Hz (a 60 Hz engine on a 120 Hz layer gets a steady 2-frame cadence
// instead of a 2-3-2 beat), else 1.
int Q2_VR_PoseDivisor(void)
{
    int d = atomic_load(&vr_ab_posediv);
    if (d > 0) return d > 4 ? 4 : d;
    int us = atomic_load(&vr_layer_period_us);
    return (us > 0 && us < 10000) ? 2 : 1;
}
int Q2_VR_LayerPeriodUs(void) { return atomic_load(&vr_layer_period_us); }
// [R21] The RAW override, before Q2_VR_PoseDivisor applies its automatic rule — 0 means
// "nobody pinned one". The adaptive divisor in q2_vr_glue.m has to distinguish a pin it must
// honour from an automatic choice it is free to move, and inferring that from the resolved
// value cannot tell `q2vrdiv 1` from no pin at all.
int Q2_VR_PoseDivisorRaw(void) { return atomic_load(&vr_ab_posediv); }

// Set by the VR glue; read by the arbitration predicate and the dumps.
static int vr_pose_valid, vr_drawable_ready;
void Q2_VR_SetPoseValid(int v)     { vr_pose_valid = v ? 1 : 0; }
void Q2_VR_SetDrawableReady(int v) { vr_drawable_ready = v ? 1 : 0; }

// R4 — the injection forwarders. This file is compiled into the iOS build too, where there is
// no Sense layer at all, so the three writes go through macros that vanish there rather than
// through a stub nobody would remember to keep in step. The local copy is kept because it is
// what the dumps echo; the Sense store is what the game actually reads.
#if defined(Q2_XR_UI) && Q2_XR_UI
extern void Q2_VR_SenseSetSynthHand(int hand, int on, float yaw, float pitch, float roll,
                                    float x, float y, float z);
extern void Q2_VR_SenseSetSynthButtons(int hand, unsigned buttons);
extern void Q2_VR_SenseSetSynthStick(int hand, float x, float y);
extern void Q2_VR_DumpHands(char *out, int outsz);
extern void Q2_VR_DumpAimFields(char *out, int outsz);
extern void Q2_VR_DumpViewmodelFields(char *out, int outsz);
#define VR_SENSE_SYNTH_HAND(h,on,y,p,r,x,yy,z)  Q2_VR_SenseSetSynthHand(h,on,y,p,r,x,yy,z)
#define VR_SENSE_SYNTH_BTN(h,b)                 Q2_VR_SenseSetSynthButtons(h,b)
#define VR_SENSE_SYNTH_STICK(h,x,y)             Q2_VR_SenseSetSynthStick(h,x,y)
#else
#define VR_SENSE_SYNTH_HAND(h,on,y,p,r,x,yy,z)  ((void)0)
#define VR_SENSE_SYNTH_BTN(h,b)                 ((void)0)
#define VR_SENSE_SYNTH_STICK(h,x,y)             ((void)0)
#endif

typedef struct {
    bool  active;
    float yaw, pitch, roll;     // degrees
    float x, y, z;              // world units
    float stickX, stickY;       // -1..1
    unsigned buttons;           // latched bitmask, so holds compose
} vr_hand_t;

static vr_hand_t vr_hand[2];    // 0 = left, 1 = right
static struct {
    float yaw, pitch;           // degrees
    float x, y, z;              // world units
    bool  overridden;
} vr_pose;
static float vr_ipd_m = 0.063f;
// The simulator's CompositorServices reports views = 1 with an identity view transform, so
// there is no eye separation to publish and nothing stereo to assert. The compositor
// synthesises this instead, which is why `q2vripd` exists and why a sim run's honest claim
// is about the renderer's own eye pair rather than about the drawable's view count.
float Q2_VR_SimIPD(void) { return vr_ipd_m; }

// The synthetic head pose, read by the VR glue as an OVERRIDE of the tracked one. This is
// what makes "the eye images respond to the pose" assertable without a headset: the
// injection lands at the same boundary a real anchor writes, so the transform chain and
// the renderer under test are the real ones, not a parallel path.
// x/y/z are head-local FORWARD/RIGHT/UP in world units, matching the eyeofs convention.
int Q2_VR_PoseOverride(float *yaw, float *pitch, float *fwd, float *right, float *up)
{
    if (!vr_pose.overridden) return 0;
    if (yaw)   *yaw = vr_pose.yaw;
    if (pitch) *pitch = vr_pose.pitch;
    if (fwd)   *fwd = vr_pose.x;
    if (right) *right = vr_pose.y;
    if (up)    *up = vr_pose.z;
    return 1;
}

// [R14b] Forward: the memory note is defined below vr_mode_name(), which this needs.
static void vr_mem_note(const char *at);

void Q2_VR_SetMode(int mode)
{
    if (vr_mode == mode) return;
    vr_mode = mode;
    char line[128];
    Q_snprintf(line, sizeof(line), "MODE transition to=%s", mode == 2 ? "vr" : mode == 1 ? "3d" : "2d");
    Q2_VR_BlackBoxPin("mode", line);
    vr_emit("%s", line);
    // [R14b] VR ENTER/EXIT is the other moment the footprint moves in one step (the eye ring
    // and its depth copies are allocated and freed here), so it gets the same line a map
    // change gets — at= names which transition it was.
    vr_mem_note(mode == 2 ? "vrenter" : "vrexit");
    Q2_VR_BlackBoxFlush(1);
}
int Q2_VR_Mode(void) { return vr_mode; }

static const char *vr_mode_name(void)
{
    return vr_mode == 2 ? "vr" : vr_mode == 1 ? "3d" : "2d";
}

// ===================================================================================
// [R14b] MEMORY BREADCRUMBS — the crash that left no reason
// ===================================================================================
// The test Vision Pro died loading base1 on OTA 1.0.11.17: the engine log ends inside the
// intro cinematic and nothing follows it — no assert, no signal, no exit line. A jetsam kill
// writes NOTHING into our own log by construction (the process is gone before any handler
// runs), and the simulator cannot reproduce it because the simulator has the Mac's memory.
// So the only way the NEXT one explains itself is for the log to already be carrying the
// number that decides it, before the kill.
//
// Two numbers, both cheap:
//   phys_footprint          — what the OS actually kills a process over. NOT resident_size,
//                             which under-reports Metal texture residency (R9's ring).
//   os_proc_available_memory — how much headroom THIS process has left before it does.
//                             It falls as the footprint climbs; a map load that reaches
//                             single-digit MB here is the jetsam, named.
//
// Three sinks, none of them per-frame: the once-a-second VRCLOCK line (compositor thread),
// one line at every map change and mode transition (engine thread, via Q2_VR_Tick), and a
// UserDefaults marker that OUTLIVES the kill so the next launch can say the last one never
// shut down — the one breadcrumb a dead process can still leave.

static _Atomic float vr_mem_peak;      // high-water footprint since launch, MB
static char          vr_last_map[64];  // "" while disconnected

// Reads both numbers and maintains the peak. Safe from either thread: the peak is a plain
// atomic load/store pair, and a lost race can only under-report by one sample of a value
// that is re-read a second later.
void Q2_VR_MemStats(float *cur_mb, float *peak_mb, float *avail_mb)
{
    float cur = 0.0f;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        cur = (float)((double)info.phys_footprint / (1024.0 * 1024.0));
    float peak = atomic_load(&vr_mem_peak);
    if (cur > peak) { peak = cur; atomic_store(&vr_mem_peak, peak); }
    // os_proc_available_memory() is the documented reader, but it returns 0 wherever the
    // process has no jetsam limit to be measured against — which is EVERY simulator run. The
    // same quantity is `limit_bytes_remaining` in the struct already fetched above (rev4+), so
    // fall back to it rather than let the field read 0 on the one platform that has no
    // headroom problem and 0 again if the wrapper ever declines on glass.
    float avail = (float)((double)os_proc_available_memory() / (1024.0 * 1024.0));
    if (avail <= 0.0f && count >= TASK_VM_INFO_REV4_COUNT &&
        info.limit_bytes_remaining != UINT64_MAX)
        avail = (float)((double)info.limit_bytes_remaining / (1024.0 * 1024.0));
    if (cur_mb)   *cur_mb = cur;
    if (peak_mb)  *peak_mb = peak;
    if (avail_mb) *avail_mb = avail;
}

// The shared field spelling, so the VRCLOCK tail, the VRMEM line and the crash marker can
// never drift apart into three formats a reader has to learn separately.
int Q2_VR_MemLine(char *out, int size)
{
    float cur = 0, peak = 0, avail = 0;
    if (!out || size <= 0) return 0;
    Q2_VR_MemStats(&cur, &peak, &avail);
    return (int)Q_snprintf(out, (size_t)size, "mem=%.0fMB/%.0fMB peak=%.0fMB", cur, avail, peak);
}

// ---- the unclean-exit marker -------------------------------------------------------
// UserDefaults rather than a file: it is atomic, it survives a SIGKILL, and it costs one
// write per map change and per mode transition — never per frame. It is ARMED whenever the
// app is in the foreground and CLEARED when the app backgrounds cleanly, so a jetsam of a
// backgrounded app (expected, uninteresting) does not raise a false alarm, while a death
// with the headset on the player's face does.
#define VR_MARK_KEY @"q2_run_marker"

static void vr_mark_write(void)
{
    char mem[96];
    Q2_VR_MemLine(mem, sizeof(mem));
    NSString *v = [NSString stringWithFormat:@"%s|%s|%s",
                   mem, vr_last_map[0] ? vr_last_map : "none", vr_mode_name()];
    [NSUserDefaults.standardUserDefaults setObject:v forKey:VR_MARK_KEY];
    [NSUserDefaults.standardUserDefaults synchronize];
}

// running=1 arms the marker (foreground), running=0 clears it (a clean background/quit).
void Q2_VR_MarkRunning(int running)
{
    if (running) vr_mark_write();
    else {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:VR_MARK_KEY];
        [NSUserDefaults.standardUserDefaults synchronize];
    }
}

// One line per map change / mode transition / launch, into BOTH sinks, and it refreshes the
// marker in the same breath so the marker's "last map" is never behind the log's.
static void vr_mem_note(const char *at)
{
    char mem[96], line[288];
    Q2_VR_MemLine(mem, sizeof(mem));
    Q_snprintf(line, sizeof(line), "VRMEM at=%s map=%s mode=%s %s",
               at, vr_last_map[0] ? vr_last_map : "none", vr_mode_name(), mem);
    Q2_VR_BlackBoxPin("mem", line);
    vr_emit("%s", line);
    vr_mark_write();
    Q2_VR_BlackBoxFlush(1);
}

// The map watch. `cl_mapname` is the engine's own console macro (client/main.c), which is a
// PUBLIC seam — reading it costs one cached pointer and one strcmp per frame and keeps
// client.h out of this file, exactly as the notify firewall above keeps it out. An empty
// name is the honest "no map" (menu, disconnect) and is itself a transition worth a line:
// the memory a map RELEASED is as diagnostic as the memory it took.
static void vr_map_watch(void)
{
    static cmd_macro_t *macro;
    static bool looked;
    char name[64];
    if (!looked) { macro = Cmd_FindMacro("cl_mapname"); looked = true; }
    name[0] = 0;
    if (macro && macro->function) macro->function(name, sizeof(name));
    if (!strcmp(name, vr_last_map)) return;
    Q_strlcpy(vr_last_map, name, sizeof(vr_last_map));
    vr_mem_note("map");
}

static const char *vr_btn_name(unsigned bit)
{
    switch (bit) {
    case 1u << 0: return "trigger";
    case 1u << 1: return "grip";
    case 1u << 2: return "a";
    case 1u << 3: return "b";
    case 1u << 4: return "stick";
    case 1u << 5: return "menu";
    default: return "none";
    }
}

static unsigned vr_btn_bit(const char *name)
{
    for (unsigned i = 0; i < 6; i++)
        if (!Q_stricmp(name, vr_btn_name(1u << i))) return 1u << i;
    return 0;
}

// Which hand the Aim Hand row currently names. Asked of the settings store rather than
// hardcoded to 'r' as R0's placeholder was — the row has been storing a value since R3 and
// this round is where it starts meaning something.
static char vr_hand_aim_label(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern int Q2_VR_AimHandSetting(void);
    return Q2_VR_AimHandSetting() ? 'r' : 'l';
#else
    return 'r';
#endif
}

static int vr_hand_index(const char *s)
{
    if (!Q_stricmp(s, "l") || !Q_stricmp(s, "left"))  return 0;
    if (!Q_stricmp(s, "r") || !Q_stricmp(s, "right")) return 1;
    return -1;
}

// ===================================================================================
// The *NOW dump family
// ===================================================================================
// Identity, not intent: where a value describes what was ACTUALLY done, say so. Where VR
// state does not exist yet, the field says `vr=off` and carries the neutral value rather
// than being omitted — a missing field breaks a regex, an honest placeholder does not.

extern int  VID_iOS_PassiveState(void);
extern bool VID_iOS_MenuActive(void);
extern bool VID_iOS_Disconnected(void);
extern bool VID_iOS_LayoutActive(void);
extern bool Q2_iOS_AutoPauseHeld(void);
#if defined(Q2_XR_UI) && Q2_XR_UI
extern int  VID_iOS_XR3_Active(void);
extern int  VID_iOS_XR3_FramesRendered(void);
extern int  VID_iOS_XR3_InFlight(void);
extern int  VID_iOS_XR3_EyeGeneration(void);
extern void VID_iOS_XR3_EyeSize(int *w, int *h);
// q2_vr_glue.m — the VR substrate's own fields, appended (never inserted) at the end of
// EYENOW and MODENOW. A field inserted mid-record lands on a junction that existing suite
// regexes span; appending is the rule this file opens with.
extern void Q2_VR_DumpEyeFields(char *out, int outsz);
extern void Q2_VR_DumpModeFields(char *out, int outsz);
extern int  Q2_VR_DepthActive(void);
// q2_vr_input.m — the player-state half (body yaw, alignment, turn state, the stash) and
// the pad heartbeat from main.m's main-queue driver.
extern void Q2_VR_DumpMoveFields(char *out, int outsz);
extern void Q2_VR_DumpBodyFields(char *out, int outsz);
extern int  Q2_VR_PadTicks(void);
extern void *VID_iOS_XR3_UITexture(void);
extern int  VID_iOS_XR3_UIReady(void);
extern void VID_iOS_XR3_UISize(int *w, int *h);
extern void Q2_VR_PaceReset(void);
extern void Q2_VR_DumpPaceFields(char *out, int outsz);
extern void Q2_VR_DumpResidualFields(char *out, int outsz);        // R7a item 2
extern void Q2_VR_DumpResidualRing(void (*emit)(const char *));    // R7a item 2
#endif

// Not behind Q2_XR_UI: the swap counter lives in the ANGLE driver, which iOS links too, and
// a frozen window is a defect either platform could grow.
extern void VID_iOS_ANGLE_SwapStats(unsigned long long *ok, unsigned long long *fail);

static float pref(NSString *key, float def)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:key] ? (float)[d floatForKey:key] : def;
}

// Which present surface a VR frame would use, and WHY — recorded as a reason code so a
// panel fallback can be diagnosed from one line instead of a guess.
// The order is the diagnosis: the FIRST failing term is the reason code, and it is the
// term a person should go and look at. Terms are ordered outermost-first (is there a game
// at all, then is it passive, then is a UI surface up, then is VR itself ready), so the
// reason never blames an inner term for an outer failure.
const char *Q2_VR_PresentReason(void)
{
    int dest = Key_GetDest();
    if (VID_iOS_Disconnected())      return "disconnected";
    if (VID_iOS_PassiveState() == 2) return "cinematic";
    if (VID_iOS_PassiveState() == 1) return "demo";
    if (dest & KEY_MENU)             return "menu";
    if (dest & KEY_CONSOLE)          return "console";
    if (dest & KEY_MESSAGE)          return "message";
    if (VID_iOS_LayoutActive())      return "layout";
    if (vr_mode == 2 && !vr_drawable_ready) return "nodrawable";
    if (vr_mode == 2 && !vr_pose_valid)     return "nopose";
    return "none";
}
// The predicate itself, so the compositor and the engine frame cannot disagree about which
// surface this frame belongs on: both ask this one function.
int Q2_VR_PresentIsWorld(void) { return !strcmp(Q2_VR_PresentReason(), "none"); }

static const char *vr_present_reason(void) { return Q2_VR_PresentReason(); }

static void dump_mode(void)
{
    const char *reason = vr_present_reason();
    char extra[160] = " owner=link vrthread=0 posevalid=0 drawable=0";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpModeFields(extra, sizeof(extra));
#endif
    vr_emit("MODENOW mode=%s xr3active=%d present=%s reason=%s passive=%d menu=%d "
            "disconnected=%d layout=%d paused=%d autopause=%d devbuild=%d%s",
            vr_mode_name(),
#if defined(Q2_XR_UI) && Q2_XR_UI
            VID_iOS_XR3_Active(),
#else
            0,
#endif
            !strcmp(reason, "none") ? "world" : "panel", reason,
            VID_iOS_PassiveState(), VID_iOS_MenuActive() ? 1 : 0,
            VID_iOS_Disconnected() ? 1 : 0, VID_iOS_LayoutActive() ? 1 : 0,
            (int)Cvar_VariableValue("cl_paused"), Q2_iOS_AutoPauseHeld() ? 1 : 0,
#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
            1,
#else
            0,
#endif
            extra);
    // [R7a item 12] APPENDED at the very end of the record, never inserted: existing suite
    // regexes anchor on the fields above. `swapok` is the count of eglSwapBuffers calls that
    // SUCCEEDED against the 2D window surface. It advancing after a VR exit is the machine
    // proof that the picture is moving again — the thing the frozen-window bug silently took
    // away while every other counter in this file kept climbing.
    {
        unsigned long long ok = 0, bad = 0;
        VID_iOS_ANGLE_SwapStats(&ok, &bad);
        vr_emit("SWAPNOW swapok=%llu swapfail=%llu", ok, bad);
    }
}

// A pinned line per ARBITRATION TRANSITION, plus a rolling entry. Pinned so the last
// transition survives any amount of tail churn: the question a device report has to answer
// is "which surface was it on, and which term put it there", and that must not be a line
// that scrolled away twenty seconds ago.
void Q2_VR_NotePresent(void)
{
    static int         lastWorld = -1;
    static char        lastReason[32];
    const char        *reason = Q2_VR_PresentReason();
    int                world = !strcmp(reason, "none");
    if (world == lastWorld && !strcmp(reason, lastReason)) return;
    lastWorld = world;
    Q_strlcpy(lastReason, reason, sizeof(lastReason));
    char line[160];
    Q_snprintf(line, sizeof(line), "ARB present=%s reason=%s mode=%s",
               world ? "world" : "panel", reason, vr_mode_name());
    Q2_VR_BlackBoxPin("arbitration", line);
    vr_emit("%s", line);
}

static void dump_eye(void)
{
    int w = 0, h = 0, gen = 0, pub = 0, inflight = 0;
#if defined(Q2_XR_UI) && Q2_XR_UI
    VID_iOS_XR3_EyeSize(&w, &h);
    gen = VID_iOS_XR3_EyeGeneration();
    pub = VID_iOS_XR3_FramesRendered();
    inflight = VID_iOS_XR3_InFlight();
#endif
    float quality = pref(@"xr_quality", 0.6f);
    float halfW = pref(@"xr_halfW", 2.75f), halfH = pref(@"xr_halfH", 1.55f);
    char extra[512] = " depth=off physw=0 physh=0 rscale=0.00 targetw=0 targeth=0 "
                      "sizedfrom=panelbudget panelrect=0x0 znear=0.0u zfar=0.0u "
                      "worldscale=34.0u_per_m depthfloor=0.000122 "
                      "tanL=0.000 tanR=0.000 tanU=0.000 tanD=0.000 "
                      "headyaw=0.0deg headpitch=0.0deg ipdeye=(0.0000,0.0000,0.0000)m "
                      "pubepoch=0 pubrefused=0";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpEyeFields(extra, sizeof(extra));
#endif
    vr_emit("EYENOW eyes=2 wpx=%d hpx=%d gen=%d published=%d inflight=%d quality=%.2f "
            "panelaspect=%.3f ipd=%.4fm vr=%s%s",
            w, h, gen, pub, inflight, quality,
            halfH > 0.01f ? halfW / halfH : 0.0f, vr_ipd_m,
            vr_mode == 2 ? "on" : "off", extra);
}

static void dump_body(void)
{
    // The alignment chain's own fields are APPENDED by q2_vr_input.m (VR builds only); the
    // leading fields keep the shape R1's suite anchors on. `eyeheight=46.0u` is the engine's
    // own standing-eye constant, published so the number the height maths deviates FROM is
    // visible beside the deviation rather than buried in a header.
    char extra[480] = " bodyyaw=0.0deg aimyaw=0.0deg aimpitch=0.0deg aimvalid=0 "
                      "viewyaw=0.0deg recenters=0 baseline=0.000m trim=0.000m eye=0.000m "
                      "rise=0.0u riseapplied=0.0u ducked=0 ceilclamp=0 stash=0 "
                      "renderyaw=0.0deg gameyaw=0.0deg serveryaw=0.0deg yawsrc=none";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpBodyFields(extra, sizeof(extra));
#endif
    vr_emit("BODYNOW vr=%s origin=(%.2f,%.2f,%.2f)u bodyyaw=%.1fdeg headyaw=%.1fdeg "
            "headpitch=%.1fdeg eyeheight=46.0u worldscale=%.1fu_per_m poseoverride=%d%s",
            vr_mode == 2 ? "on" : "off",
            vr_pose.x, vr_pose.y, vr_pose.z, vr_pose.yaw, vr_pose.yaw, vr_pose.pitch,
            vr_worldscale, vr_pose.overridden ? 1 : 0, extra);
}

static void dump_aim(void)
{
    // The R4 fields are APPENDED by q2_vr_hands.m (VR builds only), never inserted: existing
    // suite anchors sit on the leading fields and a field added in the middle lands on a
    // junction they already match.
    char extra[512] = " aimsrc=head aimhandidx=1 handaim=0 handmiss=3 aimyaw=0.0deg "
                      "aimpitch=0.0deg pitchtrim=0.0deg pitchcomp=0 handL=(0.0,0.0,0.0)deg "
                      "handR=(0.0,0.0,0.0)deg handLofs=(0.000,0.000,0.000)m "
                      "handRofs=(0.000,0.000,0.000)m posed=00 sentpitch=0.0deg "
                      "deltapitch=0.0deg";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpAimFields(extra, sizeof(extra));
#endif
    vr_emit("AIMNOW vr=%s aimhand=%c hand=(%.1f,%.1f)deg head=(%.1f,%.1f)deg "
            "sent=(%.1f,%.1f)deg handactive=%d%s",
            vr_mode == 2 ? "on" : "off",
            vr_hand_aim_label(),
            vr_hand[1].pitch, vr_hand[1].yaw, vr_pose.pitch, vr_pose.yaw,
            q2vr.view_pitch_out, q2vr.view_yaw_out,
            (vr_hand[0].active ? 1 : 0) + (vr_hand[1].active ? 2 : 0), extra);
}

static void dump_move(void)
{
    char extra[320] = " pad=0 padinj=0 padL=(0.00,0.00) padR=(0.00,0.00) movedir=head "
                      "moveyaw=0.0deg moverotate=0 moveout=(0.0,0.0) turnmode=snap "
                      "turnstep=30deg turnspeed=160deg_per_s turnarmed=1 turns=0 autopause=0";
    int padticks = 0;
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpMoveFields(extra, sizeof(extra));
    padticks = Q2_VR_PadTicks();
#endif
    // `padticks` is the heartbeat of the main-queue pad driver. Under .full immersion the
    // system stops the display link that used to poll the pad, so an ADVANCING padticks in a
    // VR run is the proof that input has a live home at all — the exact thing R1 descoped.
    vr_emit("MOVENOW vr=%s btnleft=0x%02x btnright=0x%02x stickL=(%.2f,%.2f) "
            "stickR=(%.2f,%.2f) sensx=%.2f sensy=%.2f gyro=%d padticks=%d%s",
            vr_mode == 2 ? "on" : "off",
            vr_hand[0].buttons, vr_hand[1].buttons,
            vr_hand[0].stickX, vr_hand[0].stickY, vr_hand[1].stickX, vr_hand[1].stickY,
            Cvar_VariableValue("ios_sens_x"), Cvar_VariableValue("ios_sens_y"),
            (int)Cvar_VariableValue("ios_gyro"), padticks, extra);
}

static void dump_viewmodel(void)
{
    // Identity, not intent: `cl_gun` is what the engine was TOLD; `mounted` and `vmorg` are
    // what was actually done, written by the engine at the mount site. A dump that reported
    // only the intent would have kept passing through every one of the donors' three failed
    // viewmodel-anchor rounds.
    char extra[470] = " handvalid=0 mounted=0 vmorg=(0.0,0.0,0.0)u vmang=(0.0,0.0,0.0)deg "
                      "handofs=(0.0,0.0,0.0)u grip=(0.00,0.00,0.00)u gripang=(0.0,0.0,0.0)deg "
                      "wepscale=1.00 weprow=1.00 dot=0 dotdrawn=0 dotrange=0u dotscale=1.00";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpViewmodelFields(extra, sizeof(extra));
#endif
    vr_emit("VIEWMODELNOW vr=%s cl_gun=%d gunfov=%.1fdeg hidegun=%d weaponsize=%.2f "
            "depthhack=%s drawn=%s%s",
            vr_mode == 2 ? "on" : "off",
            (int)Cvar_VariableValue("cl_gun"), Cvar_VariableValue("cl_gunfov"),
            pref(@"xr_hidegun", 0.0f) != 0.0f ? 1 : 0,
            q2vr.weapon_scale > 0.0f ? q2vr.weapon_scale : 1.0f,
            q2vr.active ? "vrgated" : "engine",
            q2vr.vm_mounted ? "hand" : "face", extra);
}

// HANDSNOW — the hardware's own answer. Its own record rather than more fields on an existing
// one, for the reason VRSETTINGSNOW got its own: the sink has a hard line cap and a truncated
// record's last field reads as absent.
static void dump_hands(void)
{
    char line[700];
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpHands(line, sizeof(line));
#else
    Q_snprintf(line, sizeof(line),
               "HANDSNOW vr=off hands=0 polls=0 controllers=none tracking=nobuild auth=0 "
               "loadfail=0 anchors=0 presentL=0 presentR=0 posedL=0 posedR=0 heldL=0 heldR=0 "
               "btnL=0x00 btnR=0x00 stickL=(0.00,0.00) stickR=(0.00,0.00) heldkeys=0 ctx=-1 "
               "flicks=0 uienter=0 uiesc=0 synth=0");
#endif
    vr_emit("%s", line);
}

// The 2D-redirect surface and the audio listener, in one record: both are "what the player's
// senses are pointed at", both are new this round, and both are things a device report has to
// be able to answer in one line.
static void dump_ui(void)
{
    int w = 0, h = 0, ready = 0, pub = 0, hw = 0, hh = 0, wide = 0;
    float dist = 1.75f;
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern float Q2_VR_UIDistance(void);
    extern void  VID_iOS_XR3_UIRect(int *w, int *h);
    extern int   VID_iOS_XR3_HudWide(void);
    VID_iOS_XR3_UISize(&w, &h);
    VID_iOS_XR3_UIRect(&hw, &hh);
    wide = VID_iOS_XR3_HudWide();
    ready = VID_iOS_XR3_UIReady();
    pub = VID_iOS_XR3_UITexture() != NULL;
    dist = Q2_VR_UIDistance();
#endif
    extern int Q2_iOS_SpatialMode(void);
    // The listener axis is the one from patch 0022's substitution — reported so "the ears
    // follow the head" is a number that can be watched moving, not a claim in a comment.
    vr_emit("UINOW vr=%s redirect=%d ready=%d published=%d wpx=%d hpx=%d dist=%.2fm "
            "spatial=%d listenervalid=%d listenerfwd=(%.2f,%.2f,%.2f) uidraw=%d "
            "hudwide=%d hudrect=%dx%d",
            vr_mode == 2 ? "on" : "off",
            q2vr.ui_redirect, ready, pub, w, h, dist,
            Q2_iOS_SpatialMode(), q2vr.listener_valid,
            q2vr.listener_axis[0][0], q2vr.listener_axis[0][1], q2vr.listener_axis[0][2],
            q2vr.ui_draw, wide, hw, hh);
}

// WHEELNOW — the weapon / inventory wheel, and the VR cursor that now drives it (R13).
// Its own record because it is the assertion channel for R13-1 and because the sink has a hard
// line cap: `activeweap` is the only field that proves a RELEASE confirmed, and a truncated
// record's last field reads as absent. The client half comes from overlay 0038 (the wheel is
// entirely client-side); the shell half is the ray that produced the cursor.
static void dump_wheel(void)
{
    extern int CL_iOS_WheelDump(char *out, int n);
    char core[430], extra[260] = " vru=0.000 vrv=0.000 vrsel=-2 vrhand=- vrposed=0 "
                                 "vrhandyaw=0.00 vrhandpitch=0.00 vrd=1.7500 vrh=0.0000 "
                                 "vrasp=1.0000 vres=1.0000 vrhub=0.000";
    core[0] = 0;
    CL_iOS_WheelDump(core, sizeof(core));
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void  Q2_VR_DumpWheelFields(char *out, int outsz);
    extern int   Q2_VR_WheelOpenMirror(void);
    extern float Q2_VR_WheelPull(void);
    Q2_VR_DumpWheelFields(extra, sizeof(extra));
    vr_emit("WHEELNOW vr=%s %s mirror=%d pull=%.2f%s",
            vr_mode == 2 ? "on" : "off", core, Q2_VR_WheelOpenMirror(),
            Q2_VR_WheelPull(), extra);
#else
    vr_emit("WHEELNOW vr=off %s mirror=0 pull=1.00%s", core, extra);
#endif
}

static void dump_msg(void)
{
    vr_emit("MSGNOW vr=%s lines=0 cols=0 centre= notify= source=placeholder",
            vr_mode == 2 ? "on" : "off");
}

static void dump_settings(void)
{
    // R3 — THE SECTION VISIBILITY RULE, and the VR rows, appended.
    //
    // The three section lists are produced by the SHIPPING function the sheet builds itself
    // from (Q2_VR_SwiftSettingsSections in VisionShell.swift), asked once per mode. That is
    // the point: a dump that carried its own copy of the rule would keep passing after the
    // sheet stopped obeying it. Asking for all three modes from one dump also means the rule
    // is assertable without driving the app into each mode to look.
    char sec2d[64] = "?", sec3d[64] = "?", secvr[64] = "?", vrrows[520] = " vrgen=-1";
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_VR_SwiftSettingsSections(int mode, char *out, int cap);
    extern void Q2_VR_DumpSettingsFields(char *out, int outsz);
    Q2_VR_SwiftSettingsSections(0, sec2d, sizeof(sec2d));
    Q2_VR_SwiftSettingsSections(1, sec3d, sizeof(sec3d));
    Q2_VR_SwiftSettingsSections(2, secvr, sizeof(secvr));
    Q2_VR_DumpSettingsFields(vrrows, sizeof(vrrows));
#endif
    // From the sheet's OWN stored keys, so a row that stops being written is visible here
    // rather than in a device report. One line, every value labelled.
    char head[640];
    Q_snprintf(head, sizeof(head),
            "SETTINGSNOW dist=%.2fm halfW=%.2fm halfH=%.2fm height=%.2fm sep=%.0fpct "
            "conv=%.0fu dim=%.2f quality=%.2f sharpen=%.2f hidegun=%d fps=%d unitsft=%d "
            "audiomode=%d volume=%.2f znear=%.2fu msaa=%d viewsize=%.0f crosshair=%d "
            "shadows=%d predict=%d",
            pref(@"xr_dist", 3.6f), pref(@"xr_halfW", 2.75f), pref(@"xr_halfH", 1.55f),
            pref(@"xr_height", 0.0f), pref(@"xr_sep_pct", 100.0f), pref(@"xr_conv", 240.0f),
            pref(@"xr_dim", 0.8f), pref(@"xr_quality", 0.6f), pref(@"xr_sharpen", 0.5f),
            pref(@"xr_hidegun", 0.0f) != 0.0f ? 1 : 0,
            pref(@"xr_fps", 0.0f) != 0.0f ? 1 : 0,
            pref(@"xr_unitsFt", 1.0f) != 0.0f ? 1 : 0,
            (int)Cvar_VariableValue("ios_audio_mode"), Cvar_VariableValue("ios_volume"),
            Cvar_VariableValue("gl_znear"), (int)Cvar_VariableValue("gl_multisamples"),
            Cvar_VariableValue("viewsize"), (int)Cvar_VariableValue("crosshair"),
            // The two archived cvars the VR stash takes away and must give back. Asserted
            // from a *NOW record rather than by echoing the cvar over the console bridge: the
            // bridge replays a LOG DELTA, so a query that produced no new log line comes back
            // as an empty string — and an empty string silently satisfied both halves of a
            // "was it overridden / was it restored" pair. INCONCLUSIVE is not green.
            (int)Cvar_VariableValue("gl_shadows"), (int)Cvar_VariableValue("cl_predict"));
    vr_emit("%s sec2d=%s sec3d=%s secvr=%s", head, sec2d, sec3d, secvr);
    // A SECOND record rather than a longer first one. The *NOW family is one line at the
    // sink and the sink has a hard line cap; SETTINGSNOW plus fourteen VR rows would have
    // been silently truncated, and a truncated record's last field reads as absent, which
    // is the failure mode this file's header warns about. Its own prefix also keeps the
    // existing suite anchors on SETTINGSNOW exactly where they were.
    vr_emit("VRSETTINGSNOW%s", vrrows);
}

// ---- commands ---------------------------------------------------------------------

#define DUMP_CMD(fn, body) static void fn(void) { body; vr_nowseq_emit(); Q2_VR_BlackBoxFlush(1); }
DUMP_CMD(Cmd_ModeNow_f,      dump_mode())
DUMP_CMD(Cmd_EyeNow_f,       dump_eye())
DUMP_CMD(Cmd_BodyNow_f,      dump_body())
DUMP_CMD(Cmd_AimNow_f,       dump_aim())
DUMP_CMD(Cmd_MoveNow_f,      dump_move())
DUMP_CMD(Cmd_ViewmodelNow_f, dump_viewmodel())
DUMP_CMD(Cmd_MsgNow_f,       dump_msg())
DUMP_CMD(Cmd_WheelNow_f,     dump_wheel())
DUMP_CMD(Cmd_UiNow_f,        dump_ui())
DUMP_CMD(Cmd_SettingsNow_f,  dump_settings())
DUMP_CMD(Cmd_HandsNow_f,     dump_hands())

// Omnibus: sample everything at ONE instant and write ONE trailing NOWSEQ, so a suite can
// assert a whole consistent snapshot from a single command and a single freshness stamp.
// R5: the pacing window, appended to the omnibus so a device session's MEASUREMENTS row
// comes out of the same one command everything else does.
static void dump_pace(void)
{
    char rec[512] = "PACENOW windowsec=0.00 pubs=0 comphz=0.0 repres=0 worstgapms=0.00 "
                    "engframes=0 enghz=0.0 engstale=0 pubepoch=0 pubrefused=0 "
                    "rendezvous=0 owner=displaylink panelframes=0 paneleyes=both";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpPaceFields(rec, sizeof(rec));
#endif
    vr_emit("%s", rec);
}

// [R7a item 2] The positional twin of YAWTRACE. One summary line plus the worst frames the
// session saw, so "did the jitter fix take?" is answerable from the black box alone — see
// Q2_VR_PoseResidualReset in q2_vr_glue.m for what the number means and why it is a
// cross-check rather than a restatement of the fix.
#if defined(Q2_XR_UI) && Q2_XR_UI
static void vr_resid_emit_row(const char *line) { vr_emit("%s", line); }
#endif

static void dump_resid(void)
{
    char rec[192] = "RESIDNOW samples=0 meanm=0.0000 worstm=0.0000 ringrows=0";
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpResidualFields(rec, sizeof(rec));
#endif
    vr_emit("%s", rec);
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_DumpResidualRing(vr_resid_emit_row);
#endif
}

static void Cmd_VRZones_f(void)
{
    dump_mode();
    dump_eye();
    dump_body();
    dump_aim();
    dump_move();
    dump_viewmodel();
    dump_hands();
    dump_msg();
    dump_wheel();
    dump_ui();
    dump_settings();
    dump_pace();
    dump_resid();
    vr_nowseq_emit();
    Q2_VR_BlackBoxFlush(1);
}

// ---- synthetic input ---------------------------------------------------------------

static void Cmd_VRHand_f(void)
{
    if (Cmd_Argc() < 3) {
        Q2_VR_ConPrintf("usage: q2vrhand <l|r> off | <l|r> <yaw> <pitch> <roll> <x> <y> <z>\n");
        return;
    }
    int h = vr_hand_index(Cmd_Argv(1));
    if (h < 0) { Q2_VR_ConPrintf("q2vrhand: hand must be l or r\n"); return; }
    if (!Q_stricmp(Cmd_Argv(2), "off")) {
        memset(&vr_hand[h], 0, sizeof(vr_hand[h]));
        VR_SENSE_SYNTH_HAND(h, 0, 0, 0, 0, 0, 0, 0);
        vr_emit("VRINJECT hand=%s state=off", h ? "r" : "l");
        return;
    }
    // OFF BY ONE, fixed in R4 and worth a line about how it survived. The command takes six
    // values plus the hand, so `q2vrhand r 0 0 0 0 0 0` is EIGHT arguments and this test
    // refused every well-formed invocation. It shipped in R0 and nothing noticed, because
    // until this round the pose injection nothing consumed was `q2vrpose` and the hand
    // commands the suites exercised were `q2vrhandbtn` and `q2vrhandstick`, whose argument
    // counts are right. An injection command that only ever printed usage is a harness that
    // silently tests nothing — which is why R4-2 asserts a hand BECOMES the aim source rather
    // than assuming the injection landed.
    if (Cmd_Argc() < 8) { Q2_VR_ConPrintf("q2vrhand: need yaw pitch roll x y z\n"); return; }
    vr_hand[h].active = true;
    vr_hand[h].yaw   = (float)atof(Cmd_Argv(2));
    vr_hand[h].pitch = (float)atof(Cmd_Argv(3));
    vr_hand[h].roll  = (float)atof(Cmd_Argv(4));
    vr_hand[h].x     = (float)atof(Cmd_Argv(5));
    vr_hand[h].y     = (float)atof(Cmd_Argv(6));
    vr_hand[h].z     = (float)atof(Cmd_Argv(7));
    // R4 — THE REAL BOUNDARY. Since R0 these commands have held a value and echoed it; they
    // now drive the OUTPUT OF THE SENSE POLL, which was their design contract from the first
    // line. The pose is stored as a finished tracking-space matrix, so an injected hand goes
    // through the identical transform chain a physical one does: the base multiply, the angle
    // extraction, the metres-to-units conversion, the arbitration, the viewmodel mount. What
    // a simulator run exercises is the shipping code, not a parallel copy of it.
    //
    // The position is METRES here even though the R0 usage line said units: the boundary is
    // the poll's output, and the poll's output is tracking space. The dumps report both.
    VR_SENSE_SYNTH_HAND(h, 1, vr_hand[h].yaw, vr_hand[h].pitch, vr_hand[h].roll,
                        vr_hand[h].x, vr_hand[h].y, vr_hand[h].z);
    vr_emit("VRINJECT hand=%s yaw=%.1fdeg pitch=%.1fdeg roll=%.1fdeg pos=(%.2f,%.2f,%.2f)m",
            h ? "r" : "l", vr_hand[h].yaw, vr_hand[h].pitch, vr_hand[h].roll,
            vr_hand[h].x, vr_hand[h].y, vr_hand[h].z);
}

// LATCHED, so holds compose: `q2vrhandbtn r trigger 1` stays down until an explicit 0.
// A one-shot that auto-releases re-arms every edge detector downstream and makes a held
// input impossible to test.
static void Cmd_VRHandBtn_f(void)
{
    if (Cmd_Argc() < 3) {
        Q2_VR_ConPrintf("usage: q2vrhandbtn <l|r> <trigger|grip|a|b|stick|menu|none> [0|1]\n");
        return;
    }
    int h = vr_hand_index(Cmd_Argv(1));
    if (h < 0) { Q2_VR_ConPrintf("q2vrhandbtn: hand must be l or r\n"); return; }
    if (!Q_stricmp(Cmd_Argv(2), "none")) {
        vr_hand[h].buttons = 0;
        VR_SENSE_SYNTH_BTN(h, 0);
        vr_emit("VRINJECT hand=%s buttons=0x00", h ? "r" : "l");
        return;
    }
    unsigned bit = vr_btn_bit(Cmd_Argv(2));
    if (!bit) { Q2_VR_ConPrintf("q2vrhandbtn: unknown button '%s'\n", Cmd_Argv(2)); return; }
    bool down = Cmd_Argc() > 3 ? atoi(Cmd_Argv(3)) != 0 : true;
    if (down) vr_hand[h].buttons |= bit; else vr_hand[h].buttons &= ~bit;
    VR_SENSE_SYNTH_BTN(h, vr_hand[h].buttons);
    vr_emit("VRINJECT hand=%s button=%s down=%d buttons=0x%02x",
            h ? "r" : "l", vr_btn_name(bit), down ? 1 : 0, vr_hand[h].buttons);
}

static void Cmd_VRHandStick_f(void)
{
    if (Cmd_Argc() < 4) { Q2_VR_ConPrintf("usage: q2vrhandstick <l|r> <x -1..1> <y -1..1>\n"); return; }
    int h = vr_hand_index(Cmd_Argv(1));
    if (h < 0) { Q2_VR_ConPrintf("q2vrhandstick: hand must be l or r\n"); return; }
    vr_hand[h].stickX = Q_clipf((float)atof(Cmd_Argv(2)), -1.0f, 1.0f);
    vr_hand[h].stickY = Q_clipf((float)atof(Cmd_Argv(3)), -1.0f, 1.0f);
    VR_SENSE_SYNTH_STICK(h, vr_hand[h].stickX, vr_hand[h].stickY);
    vr_emit("VRINJECT hand=%s stick=(%.2f,%.2f)", h ? "r" : "l",
            vr_hand[h].stickX, vr_hand[h].stickY);
}

static void Cmd_VRPose_f(void)
{
    if (Cmd_Argc() < 2) {
        vr_pose.overridden = false;
        memset(&vr_pose, 0, sizeof(vr_pose));
        vr_emit("VRINJECT pose=cleared");
        return;
    }
    if (Cmd_Argc() < 6) { Q2_VR_ConPrintf("usage: q2vrpose [yaw pitch x y z]\n"); return; }
    vr_pose.yaw   = (float)atof(Cmd_Argv(1));
    vr_pose.pitch = (float)atof(Cmd_Argv(2));
    vr_pose.x     = (float)atof(Cmd_Argv(3));
    vr_pose.y     = (float)atof(Cmd_Argv(4));
    vr_pose.z     = (float)atof(Cmd_Argv(5));
    vr_pose.overridden = true;
    vr_emit("VRINJECT pose yaw=%.1fdeg pitch=%.1fdeg pos=(%.2f,%.2f,%.2f)u",
            vr_pose.yaw, vr_pose.pitch, vr_pose.x, vr_pose.y, vr_pose.z);
}

// Exists because CompositorServices in the SIMULATOR reports views=1 with an identity
// pose: without a synthesised IPD there is no stereo to assert on the sim at all. The
// honest claim a sim run can make is the RENDERER's own eye-pair count, never "per eye
// on views=2".
static void Cmd_VRIpd_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vripd %.4fm\n", vr_ipd_m); return; }
    vr_ipd_m = Q_clipf((float)atof(Cmd_Argv(1)), 0.0f, 0.12f);
    vr_emit("VRINJECT ipd=%.4fm", vr_ipd_m);
}

// q2vrshot [eye 0|1] [name] — engine-side composite readback to a PPM. Window grabs of
// immersive content are useless (the visionOS sim composites it nowhere a screenshot can
// see), so this is the only channel a pixel assertion has. Assertions must be
// DIFFERENTIAL: take a shot of the state you are measuring against in the SAME run and
// subtract, because any fixed region goes stale.
static void Cmd_VRShot_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern int Q2_VR_EyeShot(int eye, const char *path);
    extern int Q2_VR_EyeShotPair(const char *path0, const char *path1);
    const char *arg = Cmd_Argc() > 1 ? Cmd_Argv(1) : "0";
    const char *name = Cmd_Argc() > 2 ? Cmd_Argv(2) : "eye";
    NSString *dir = [bb_path() stringByDeletingLastPathComponent];
    // `q2vrshot pair <name>` writes BOTH eyes of ONE published pair (see Q2_VR_EyeShotPair).
    // Any assertion that compares the eyes to each other must use this and not two commands.
    if (!strcmp(arg, "pair")) {
        NSString *o0 = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%s-e0.ppm", name]];
        NSString *o1 = [dir stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"%s-e1.ppm", name]];
        int rc = Q2_VR_EyeShotPair(o0.UTF8String, o1.UTF8String);
        vr_emit("VRSHOT eye=pair rc=%d path=%s", rc, o0.UTF8String);
        return;
    }
    int eye = atoi(arg);
    if (eye < 0 || eye > 2) eye = 0;          // 0/1 = the eye pair, 2 = the UI texture
    NSString *out = [dir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%s-e%d.ppm", name, eye]];
    int rc = Q2_VR_EyeShot(eye, out.UTF8String);
    vr_emit("VRSHOT eye=%d rc=%d path=%s", eye, rc, out.UTF8String);
#else
    Q2_VR_ConPrintf("q2vrshot: no per-eye textures in this build (visionOS 2D+3D only)\n");
#endif
}

// q2vrdepthshot [name] — PER-EYE DEPTH READBACK of the currently published pair (R11).
//
// The colour readback (`q2vrshot`) cannot see this class of fault at all: visionOS reprojects
// each eye against the DEPTH we submit, so an eye whose depth attachment was lost, cleared or
// stored as DontCare around an interrupted Metal render pass shows a perfectly good colour
// image that wobbles under head motion — and eye 0 is the one eye whose pass the 2D redirect
// interrupts. Two correct eyes differ only by parallax, so `absdiff_mean` is small; a stale or
// garbage eye reads large, or saturates (zero%/one% near 100).
//
// Writes two 16-bit PGMs beside the PPMs `q2vrshot` writes and emits ONE VRDEPTH line.
static void Cmd_VRDepthShot_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern int Q2_VR_DepthShotPair(const char *p0, const char *p1, char *line, int linesz);
    const char *name = Cmd_Argc() > 1 ? Cmd_Argv(1) : "depth";
    NSString *dir = [bb_path() stringByDeletingLastPathComponent];
    NSString *o0 = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%s-e0.pgm", name]];
    NSString *o1 = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"%s-e1.pgm", name]];
    char line[768] = "";
    int rc = Q2_VR_DepthShotPair(o0.UTF8String, o1.UTF8String, line, sizeof line);
    if (rc == 0 && line[0]) vr_emit("%s", line);
    else vr_emit("VRDEPTH rc=%d path=%s", rc, o0.UTF8String);
#else
    Q2_VR_ConPrintf("q2vrdepthshot: no per-eye textures in this build (visionOS 2D+3D only)\n");
#endif
}

// q2vrpubfence [0|1|2|3] — THE R14 PUBLISH-FENCE A/B, live.
//
// The flicker diagnosis' decisive instrument: is the eye pair published before eye 1's GPU
// work has retired, so the compositor samples the slot's previous occupant? The four modes
// are documented beside the state in xr3_glue.m; the short form is 0 = today, 1 = schedule
// barrier, 2 = glFinish (costs fps, and is the confirmation not the ship), 3 = the GPU-side
// cross-queue wait, which is the default. Settable from the tailnet console mid-session
// because the symptom is warm-up-shaped: it is worst at load and gone in minutes, so a build
// flag could never A/B it inside one map.
//
// Emits the mode it latched. The COST of the mode is reported once a second by the
// compositor's own `VRPUB mode=.. fence_us=mean/max` line.
static void Cmd_VRPubFence_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void VID_iOS_XR3_SetPubFence(int mode);
    extern int  VID_iOS_XR3_PubFence(void);
    if (Cmd_Argc() > 1) VID_iOS_XR3_SetPubFence(atoi(Cmd_Argv(1)));
    vr_emit("VRPUBFENCE mode=%d", VID_iOS_XR3_PubFence());
#else
    Q2_VR_ConPrintf("q2vrpubfence: no stereo publish in this build (visionOS 2D+3D only)\n");
#endif
}

// q2vrdepthspike [w h] — the charter D3 go/no-go, run in-process against the ANGLE build
// the app links, with the engine's own context current. See xr3_depth_spike.m.
static void Cmd_VRDepthSpike_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI && defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
    extern void Q2_VR_DepthSpike(int w, int h);
    int w = Cmd_Argc() > 2 ? atoi(Cmd_Argv(1)) : 0;
    int h = Cmd_Argc() > 2 ? atoi(Cmd_Argv(2)) : 0;
    Q2_VR_DepthSpike(w, h);
    Q2_VR_BlackBoxFlush(1);
#else
    Q2_VR_ConPrintf("q2vrdepthspike: dev visionOS 2D+3D builds only\n");
#endif
}

// q2vrscale [u/m] — the world-scale back door (charter D7: console only, no settings row).
static void Cmd_VRScale_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrscale %.2fu_per_m\n", vr_worldscale); return; }
    vr_worldscale = Q_clipf((float)atof(Cmd_Argv(1)), 8.0f, 128.0f);
    vr_emit("VRSET worldscale=%.2fu_per_m", vr_worldscale);
}

#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
// q2vrdepthfloor [0..1] — the sky fault injector. 0 restores the black-sky bug exactly,
// which is how a device session proves causality in one command instead of five builds.
// DEV BUILDS ONLY: its whole purpose is to put the renderer back into a known-broken
// state, so it has no business on a player's console.
static void Cmd_VRDepthFloor_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrdepthfloor %.6f\n", vr_depth_floor); return; }
    vr_depth_floor = Q_clipf((float)atof(Cmd_Argv(1)), 0.0f, 0.5f);
    vr_emit("VRSET depthfloor=%.6f", vr_depth_floor);
}
#endif  // Q2_DEV_BUILD — fault injectors are dev-build only

// q2vrended — the Digital Crown stand-in (see VRShell.swift for exactly what it proves).
static void Cmd_VREnded_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_VR_SwiftSystemDismiss(void);
    Q2_VR_SwiftSystemDismiss();
    vr_emit("VRENDED requested");
#else
    Q2_VR_ConPrintf("q2vrended: visionOS builds only\n");
#endif
}

// q2vrenter — the Exit-VR pill's twin, so a simulator can drive a WHOLE enter/exit cycle
// inside ONE process. Before this existed the only way into VR without hands was the
// Q2_VR_AUTOENTER env var, which fires once, 12 s after the scene appears — too early to
// set anything up first, so any case needing a known pre-entry state had to relaunch, and
// a relaunch drags whatever else the launch does into the measurement. Same seam shape as
// q2vrended: it sets the model's mode and nothing else, so it runs the SHIPPING transition
// rather than a test-only path beside it.
static void Cmd_VREnter_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_VR_SwiftEnterVR(void);
    Q2_VR_SwiftEnterVR();
    vr_emit("VRENTER requested");
#else
    Q2_VR_ConPrintf("q2vrenter: visionOS builds only\n");
#endif
}

#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
// q2vrfaultentry <mask> — [R23] drive the entry watch's failure states on demand.
// bit 1: the compositor reports no device anchor; bit 2: it reports no adopted pair. Both
// are what the two black-entry states look like TO THE DETECTOR, so the VRENTRY verdict, the
// self-heal and the recovery line can all be exercised on a simulator where the real race
// did not reproduce in 42 entries. The heal clears the mask, which is what makes the second
// VRENTRY line a measurement of the repair rather than of the fault.
static void Cmd_VRFaultEntry_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_VR_SetEntryFault(int mask);
    extern int  Q2_VR_EntryFault(void);
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrfaultentry: mask=%d (1 = no anchor, 2 = no pair)\n",
                        Q2_VR_EntryFault());
        return;
    }
    int mask = atoi(Cmd_Argv(1));
    Q2_VR_SetEntryFault(mask);
    vr_emit("VRFAULT entry mask=%d", mask);
#else
    Q2_VR_ConPrintf("q2vrfaultentry: visionOS builds only\n");
#endif
}
#endif  // Q2_DEV_BUILD — fault injectors are dev-build only

// q2_scenephase 0|1 — fire the SwiftUI shell's scene-phase forwarding by hand.
// [R16] The suspected flicker mechanism is a `.active` scene phase landing AFTER VR entry
// paused the display link: Q2_XR3_ScenePhase(1) unpauses it, and the main thread starts
// driving Qcommon_Frame concurrently with the VR engine thread. On device that is a race
// nobody can schedule; this command makes it deterministic, so the guard can be A/B'd.
// It hops to the MAIN QUEUE because in VR this console runs on the engine thread and
// Q2_XR3_ScenePhase touches UIKit-adjacent state (the link, the audio session).
static void Cmd_ScenePhase_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_XR3_ScenePhase(int active);
    int active = (Cmd_Argc() > 1) ? atoi(Cmd_Argv(1)) : 1;
    dispatch_async(dispatch_get_main_queue(), ^{ Q2_XR3_ScenePhase(active); });
    vr_emit("SCENEPHASE requested active=%d", active);
#else
    Q2_VR_ConPrintf("q2_scenephase: visionOS builds only\n");
#endif
}

// ===================================================================================
// q2vryawtrace — the per-FRAME yaw record (R3)
// ===================================================================================
// The look-jitter root cause is a per-frame relationship, and every other instrument here
// samples between frames: a dump taken a second after a pose change shows a yaw that has
// long since caught up, whichever way it got there. This ring records the four numbers ON
// EVERY ENGINE FRAME, so `q2vryawtrace` is the one command that answers, live over the
// console on the headset, whether the rendered yaw moves with the head pose frame by frame
// or in the steps of the client simulation.
//
// HOW TO READ IT (the distinguishing procedure — QUESTIONS.md carries this too). Turn the
// head steadily and run `q2vryawtrace`:
//   * render tracking the pose  -> `render - body - head - server` is 0.0 on every row, and
//     `head` advances smoothly row to row. This is the fixed behaviour.
//   * render lagging the sim    -> `game` (the client-simulated yaw) repeats across runs of
//     rows and steps, and `render` follows `game` rather than `head`. That is the R2 shape,
//     and it is what the compositor reprojected against a fresher pose.
// The residual column is the whole test: it cannot be non-zero unless something other than
// the published pose is composing the camera.
#define VR_YAW_TRACE 64
static struct { float render, game, head, body, server; unsigned ms; } vr_yaw_ring[VR_YAW_TRACE];
static int vr_yaw_head_idx, vr_yaw_count;

static void vr_yaw_trace_sample(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern float Q2_VR_BodyYaw(void);
    extern float Q2_VR_LastHeadYaw(void);
    if (vr_mode != 2) return;
    int i = vr_yaw_head_idx;
    vr_yaw_ring[i].render = q2vr.render_yaw;
    vr_yaw_ring[i].game   = q2vr.game_yaw;
    vr_yaw_ring[i].head   = Q2_VR_LastHeadYaw();
    vr_yaw_ring[i].body   = Q2_VR_BodyYaw();
    vr_yaw_ring[i].server = q2vr.server_yaw;
    vr_yaw_ring[i].ms     = (unsigned)Sys_Milliseconds();
    vr_yaw_head_idx = (i + 1) % VR_YAW_TRACE;
    if (vr_yaw_count < VR_YAW_TRACE) vr_yaw_count++;
#endif
}

static void Cmd_VRYawTrace_f(void)
{
    if (!vr_yaw_count) {
        Q2_VR_ConPrintf("q2vryawtrace: nothing recorded (VR frames only)\n");
        return;
    }
    vr_emit("YAWTRACE rows=%d cols=ms,render,game,head,body,server,residual", vr_yaw_count);
    for (int n = 0; n < vr_yaw_count; n++) {
        int i = (vr_yaw_head_idx - vr_yaw_count + n + VR_YAW_TRACE * 2) % VR_YAW_TRACE;
        float resid = vr_yaw_ring[i].render - vr_yaw_ring[i].body
                    - vr_yaw_ring[i].head - vr_yaw_ring[i].server;
        while (resid > 180.0f) resid -= 360.0f;
        while (resid < -180.0f) resid += 360.0f;
        vr_emit("YAWROW %u %.2f %.2f %.2f %.2f %.2f %.3f",
                vr_yaw_ring[i].ms, vr_yaw_ring[i].render, vr_yaw_ring[i].game,
                vr_yaw_ring[i].head, vr_yaw_ring[i].body, vr_yaw_ring[i].server, resid);
    }
    vr_nowseq_emit();
}

// q2vrset <key> <value> — write ONE settings-store key and bump the generation, exactly as
// the SwiftUI sheet does. It exists because every VR row lives in NSUserDefaults and the
// visionOS simulator cannot be tapped: without it the settings section would be the one
// shipping surface with no assertion at all. The point is that it writes the SAME store the
// sheet writes and bumps the SAME counter the engine watches, so what a suite exercises is
// the shipping application path and not a test-only shortcut beside it.
//
// Types are declared here rather than inferred, because `vr_hudpos 2` stored as a double and
// read back as a bool is the kind of thing that works until the day a row changes shape.
static void Cmd_VRSet_f(void)
{
    static const struct { const char *key; char type; } rows[] = {
        { "vr_heighttrim", 'f' }, { "vr_quality",   'f' }, { "vr_sharpen",   'f' },
        { "vr_snapstep",   'f' }, { "vr_turnspeed", 'f' }, { "vr_pitchtrim", 'f' },
        { "vr_weaponsize", 'f' }, { "vr_hudsize",  'f' }, { "vr_hudheight", 'f' },
        { "vr_crosshairsize", 'f' },
        // [R23] HUD Spread. Float, like the other two HUD rows, so `q2vrset vr_hudspread 1.5`
        // writes the same shape the sheet writes — which is what lets the suite prove the row
        // through the shipping settings path on a simulator that cannot be tapped.
        { "vr_hudspread",  'f' },
        { "vr_aimhand",    'i' }, { "vr_movedir",   'i' }, { "vr_hudpos",    'i' },
        // [R20] VR Anti-aliasing (0 / 2 / 4 samples). Integer, like every other picker row,
        // so `q2vrset vr_msaa 4` writes the same shape the sheet writes.
        { "vr_msaa",       'i' },
        { "vr_migration",  'i' },
        // R11 — WHICH EYE HOSTS THE 2D REDIRECT (0 = eye 0, today; 1 = eye 1; 2 = a pass of
        // its own after both eyes). Console-only: it has no sheet row, because a control that
        // only means something while an experiment is running does not belong in front of a
        // player. It rides this table anyway so it is written through the SAME store and the
        // SAME generation counter every shipping row uses.
        { "vr_ui_eye",     'i' },
        { "vr_crosshair",  'b' }, { "vr_haptics",   'b' },
        // [R21] The FPS Counter row. Boolean, like every other toggle row, so
        // `q2vrset vr_fps 1` writes the same shape the sheet writes — which is what lets the
        // suite prove the UI-texture capture WITHOUT a tap the visionOS simulator cannot
        // deliver. Note the shell applies the draw-object on VR ENTRY and on the row's own
        // change; a `q2vrset` while already in VR writes the store, so re-enter (or toggle the
        // row) for the counter to appear.
        { "vr_fps",        'b' },
        // [R21] Menu Panel Size, degrees across (40...90). Float, and read live by the
        // compositor through XR3.panelDegrees rather than through the settings generation, so
        // a write here moves the quad on the next frame and logs VRPANELSIZE.
        { "vr_panelsize",  'f' },
        // RETIRED ROWS, still writable. R8 deleted the six grip sliders and stamp 2
        // force-deletes their keys — and a deletion nothing can plant is a deletion nothing
        // can test. They are here so the migration case can build the store a 1.0.11.10
        // player actually has, through this same shipping write path, rather than by editing
        // the plist behind cfprefsd's back (which loses the race with its own flush).
        { "vr_gripfwd",    'f' }, { "vr_gripright", 'f' }, { "vr_gripup",   'f' },
        { "vr_grippitch",  'f' }, { "vr_gripyaw",   'f' }, { "vr_griproll", 'f' },
        // [R21] vr_stats joins them: the VR Stats row is gone and stamp 4 force-deletes the
        // key, so it stays writable here for exactly the same reason the grip rows do — a
        // deletion nothing can plant is a deletion nothing can test.
        { "vr_stats",      'b' },
    };
    if (Cmd_Argc() < 3) {
        Q2_VR_ConPrintf("usage: q2vrset <key> <value>   (the settings STORE, as the sheet writes it)\n");
        for (int i = 0; i < (int)(sizeof(rows) / sizeof(rows[0])); i++)
            Q2_VR_ConPrintf("  %s (%c)\n", rows[i].key, rows[i].type);
        return;
    }
    const char *k = Cmd_Argv(1);
    double v = atof(Cmd_Argv(2));
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    for (int i = 0; i < (int)(sizeof(rows) / sizeof(rows[0])); i++) {
        if (strcmp(rows[i].key, k)) continue;
        switch (rows[i].type) {
        case 'i': [d setInteger:(NSInteger)v forKey:@(k)]; break;
        case 'b': [d setBool:(v != 0.0) forKey:@(k)]; break;
        default:  [d setDouble:v forKey:@(k)]; break;
        }
        // LAST, after the value is stored — the engine applies on this counter, so a
        // generation it observes must never describe a store that is still being written.
        [d setInteger:[d integerForKey:@"vr_gen"] + 1 forKey:@"vr_gen"];
        vr_emit("VRSET store %s=%s gen=%d", k, Cmd_Argv(2), (int)[d integerForKey:@"vr_gen"]);
        return;
    }
    Q2_VR_ConPrintf("q2vrset: %s is not a VR settings row\n", k);
}

// Q-VR7. What the boot-config carry-across did on THIS launch, straight from the shell's own
// record. Asserted rather than inferred: a settings value that survived a relaunch is also
// what you would see if the value happened to be the engine default, and a suite that cannot
// tell those apart is a suite that passes on a broken migration.
extern void Q2_iOS_BootConfigReport(char *out, int outsz);
static void Cmd_BootCfgNow_f(void)
{
    char rep[512] = "BOOTCFGNOW state=unavailable games=0 migrated=0 sanitized=0";
    Q2_iOS_BootConfigReport(rep, sizeof(rep));
    vr_emit("%s", rep);
    vr_nowseq_emit();
}

// R5: VR pacing, in one line, ready to become a MEASUREMENTS row. `q2vrpace reset` zeroes
// the window; entering VR zeroes it as well, so a device session is dump-only.
// [R17] The compositor A/B switches (see the flags beside vr_depth_floor). Each prints its
// state as a VRAB line so the black box records every flip beside the pacing counters.
static void vr_ab_set(atomic_int *flag, const char *name, int lo, int hi)
{
    if (Cmd_Argc() > 1) {
        int v = atoi(Cmd_Argv(1));
        if (v < lo) v = lo;
        if (v > hi) v = hi;
        atomic_store(flag, v);
    }
    vr_emit("VRAB %s=%d freerun=%d depthmode=%d anchormode=%d posediv=%d(auto->%d) freeze=%d mono=%d layerus=%d",
            name, atomic_load(flag),
            atomic_load(&vr_ab_freerun), atomic_load(&vr_ab_depthmode), atomic_load(&vr_ab_anchormode),
            atomic_load(&vr_ab_posediv), Q2_VR_PoseDivisor(), atomic_load(&vr_ab_freeze),
            atomic_load(&vr_ab_mono), atomic_load(&vr_layer_period_us));
}
static void Cmd_VRFreeRun_f(void)  { vr_ab_set(&vr_ab_freerun, "freerun", 0, 1); }
static void Cmd_VRDepthMode_f(void){ vr_ab_set(&vr_ab_depthmode, "depthmode", 0, 1); }
static void Cmd_VRAnchor_f(void)   { vr_ab_set(&vr_ab_anchormode, "anchormode", 0, 1); }
static void Cmd_VRDiv_f(void)      { vr_ab_set(&vr_ab_posediv, "posediv", 0, 4); }
static void Cmd_VRFreeze_f(void)   { vr_ab_set(&vr_ab_freeze, "freeze", 0, 1); }
static void Cmd_VRMono_f(void)     { vr_ab_set(&vr_ab_mono, "mono", 0, 1); }

static void Cmd_VRPace_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    if (Cmd_Argc() >= 2 && !strcmp(Cmd_Argv(1), "reset")) Q2_VR_PaceReset();
#endif
    dump_pace();
    {
        // [R17] The compositor's own once-a-second lines, pinned by VRShell.swift, so ONE
        // command answers "layer rate, wait, late, mainticks, lag, stale" as well.
        char pinned[512];
        if (Q2_VR_BlackBoxPinGet("clock", pinned, sizeof pinned)) vr_emit("%s", pinned);
        if (Q2_VR_BlackBoxPinGet("anchor", pinned, sizeof pinned)) vr_emit("%s", pinned);
        if (Q2_VR_BlackBoxPinGet("slot", pinned, sizeof pinned)) vr_emit("%s", pinned);
        // [R21] The pacing round's three: the GPU timer (engine and compositor ms), the
        // adaptive divisor's own verdict, and the publish/present sync line. Same shape and
        // the same one command, so a pacing question never needs a second round trip.
        if (Q2_VR_BlackBoxPinGet("gpu", pinned, sizeof pinned)) vr_emit("%s", pinned);
        if (Q2_VR_BlackBoxPinGet("div", pinned, sizeof pinned)) vr_emit("%s", pinned);
        if (Q2_VR_BlackBoxPinGet("pacesync", pinned, sizeof pinned)) vr_emit("%s", pinned);
    }
    vr_nowseq_emit();
}

// R7a item 2. `q2vrresid reset` zeroes the window, exactly as q2vrpace does; entering VR
// zeroes it too (Q2_VR_PaceReset is called from the rendezvous arm), so a device session
// costs no setup. The same two lines are auto-pinned into the black box every second by
// Q2_VR_Tick below, which is what makes the verdict readable without this command at all.
static void Cmd_VRResid_f(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    if (Cmd_Argc() >= 2 && !strcmp(Cmd_Argv(1), "reset")) Q2_VR_PaceReset();
#endif
    dump_resid();
    vr_nowseq_emit();
}

static void Cmd_VRBlackBox_f(void)
{
    Q2_VR_BlackBoxFlush(1);
    Q2_VR_ConPrintf("black box flushed to %s\n", bb_path().UTF8String);
}

// ===================================================================================

void Q2_VR_RegisterCommands(void)
{
    Cmd_AddCommand("q2vrmode",      Cmd_ModeNow_f);
    Cmd_AddCommand("q2vreye",       Cmd_EyeNow_f);
    Cmd_AddCommand("q2vrbody",      Cmd_BodyNow_f);
    Cmd_AddCommand("q2vraim",       Cmd_AimNow_f);
    Cmd_AddCommand("q2vrmove",      Cmd_MoveNow_f);
    Cmd_AddCommand("q2vrviewmodel", Cmd_ViewmodelNow_f);
    Cmd_AddCommand("q2vrmsg",       Cmd_MsgNow_f);
    Cmd_AddCommand("q2vrwheel",     Cmd_WheelNow_f);
    Cmd_AddCommand("q2vrui",        Cmd_UiNow_f);
    Cmd_AddCommand("q2vrsettings",  Cmd_SettingsNow_f);
    Cmd_AddCommand("q2vrzones",     Cmd_VRZones_f);
    Cmd_AddCommand("handsnow",      Cmd_HandsNow_f);
    Cmd_AddCommand("q2vrhand",      Cmd_VRHand_f);
    Cmd_AddCommand("q2vrhandbtn",   Cmd_VRHandBtn_f);
    Cmd_AddCommand("q2vrhandstick", Cmd_VRHandStick_f);
    Cmd_AddCommand("q2vrpose",      Cmd_VRPose_f);
    Cmd_AddCommand("q2vripd",       Cmd_VRIpd_f);
    Cmd_AddCommand("q2vrbb",        Cmd_VRBlackBox_f);
    Cmd_AddCommand("q2vrscale",     Cmd_VRScale_f);
#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
    Cmd_AddCommand("q2vrdepthfloor", Cmd_VRDepthFloor_f);
#endif  // Q2_DEV_BUILD — fault injectors are dev-build only
    Cmd_AddCommand("q2vrended",     Cmd_VREnded_f);
    Cmd_AddCommand("q2vrenter",     Cmd_VREnter_f);
#if defined(Q2_DEV_BUILD) && Q2_DEV_BUILD
    Cmd_AddCommand("q2vrfaultentry", Cmd_VRFaultEntry_f);
#endif  // Q2_DEV_BUILD — fault injectors are dev-build only
    Cmd_AddCommand("q2_scenephase", Cmd_ScenePhase_f);
    Cmd_AddCommand("q2vrshot",      Cmd_VRShot_f);
    Cmd_AddCommand("q2vrdepthshot", Cmd_VRDepthShot_f);
    Cmd_AddCommand("q2vrdepthspike", Cmd_VRDepthSpike_f);
    Cmd_AddCommand("q2vrpubfence", Cmd_VRPubFence_f);
    Cmd_AddCommand("q2vryawtrace", Cmd_VRYawTrace_f);
    Cmd_AddCommand("q2vrset",      Cmd_VRSet_f);
    Cmd_AddCommand("q2bootcfg",    Cmd_BootCfgNow_f);
    Cmd_AddCommand("q2vrpace",     Cmd_VRPace_f);
    Cmd_AddCommand("q2vrresid",    Cmd_VRResid_f);
    // [R17] the compositor A/B switches
    Cmd_AddCommand("q2vrfreerun",  Cmd_VRFreeRun_f);
    Cmd_AddCommand("q2vrdepth",    Cmd_VRDepthMode_f);
    Cmd_AddCommand("q2vranchor",   Cmd_VRAnchor_f);
    Cmd_AddCommand("q2vrdiv",      Cmd_VRDiv_f);
    Cmd_AddCommand("q2vrfreeze",   Cmd_VRFreeze_f);
    Cmd_AddCommand("q2vrmono",     Cmd_VRMono_f);

    Q2_VR_BlackBoxPin("boot", "BOOT harness registered: dumps, injection, black box");

    // [R14b] THE LINE A DEAD PROCESS LEAVES BEHIND. Read the previous run's marker BEFORE
    // arming this one: if it is still there, the last launch never reached a clean
    // background, which for a foreground jetsam is the only evidence that exists.
    {
        NSString *prev = [NSUserDefaults.standardUserDefaults stringForKey:VR_MARK_KEY];
        if (prev.length) {
            NSArray<NSString *> *f = [prev componentsSeparatedByString:@"|"];
            char line[352];
            Q_snprintf(line, sizeof(line),
                       "PREVIOUS RUN ENDED WITHOUT CLEAN SHUTDOWN (last %s, last map=%s, last mode=%s)",
                       f.count > 0 ? f[0].UTF8String : "mem=?",
                       f.count > 1 ? f[1].UTF8String : "?",
                       f.count > 2 ? f[2].UTF8String : "?");
            Q2_VR_BlackBoxPin("unclean", line);
            vr_emit("%s", line);
        }
    }
    vr_mem_note("launch");
    Q2_VR_BlackBoxFlush(1);
}

// [R7a item 2] CONTINUOUS AUTO-CAPTURE. The two lines that decide whether the jitter fix
// took — the positional residual and the pacing window, which now carries the panel-miss
// count behind the left-eye flicker — are PINNED into the black box once a second for the
// whole of every VR session. Pinned, so each rewrite replaces the last and the region cannot
// be rolled away by a chatty tail; and via BlackBoxPin rather than vr_emit, because a
// diagnostic that prints is a diagnostic in the player's notify feed (guide S7).
//
// This is the difference between "someone runs six console commands in the headset" and
// "someone plays for five minutes and the file already knows".
static void vr_autocapture(void)
{
#if defined(Q2_XR_UI) && Q2_XR_UI
    static unsigned last_ms;
    unsigned now = (unsigned)Sys_Milliseconds();
    char rec[512];
    if (vr_mode != 2) return;
    if (last_ms && now - last_ms < 1000) return;
    last_ms = now ? now : 1;
    Q2_VR_DumpResidualFields(rec, sizeof(rec));
    Q2_VR_BlackBoxPin("resid", rec);
    Q2_VR_DumpPaceFields(rec, sizeof(rec));
    Q2_VR_BlackBoxPin("pace", rec);
#endif
}

// Called once per engine frame. The ~1 Hz coalescing lives inside Flush, so this is a
// cheap timestamp comparison on every frame that is not the one that writes.
void Q2_VR_Tick(void)
{
    vr_yaw_trace_sample();
    vr_autocapture();
    vr_map_watch();     // [R14b] one strcmp; emits only on a real map transition
    Q2_VR_BlackBoxFlush(0);
}
