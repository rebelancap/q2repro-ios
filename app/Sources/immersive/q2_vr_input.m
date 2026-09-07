// q2_vr_input.m — VR gameplay input, the alignment chain, and the crash-safe cvar stash.
//
// WHY THIS IS A SEPARATE FILE FROM q2_vr_glue.m. The glue owns frame ownership, the pose
// rendezvous and the per-eye render gate — things that are true of a FRAME. This file owns
// things that are true of a PLAYER: which way their body faces, how tall they are, what the
// stick did, and which cvars were taken away from them while they are in there. Both are
// engine-header C compiled beside the compositor's Swift, but mixing them produced one file
// where every function needed a comment saying which half it belonged to.
//
// THE ONE-SENTENCE TRICK THIS FILE IS BUILT ON (guide 12.7). `cl.viewangles` is what the
// client SENDS; the VR camera does not come from it — the camera comes from the published
// head pose, composed at the view.c site. So writing the head's angles into `cl.viewangles`
// makes stock progs, every mod, the campaign and multiplayer all see ordinary view angles,
// with no protocol change and no server-side anything. Aim and camera are decoupled by
// construction, which is also why a gamepad stick can turn the body while the head keeps
// looking wherever it likes.
//
// AND THE COROLLARY THAT IS EASY TO GET WRONG. Because the head yaw goes out through
// `cl.viewangles`, it comes BACK through the engine's own view angles
// (`cl.predicted_angles = cl.viewangles + delta_angles`, predict.c, no smoothing anywhere).
// So the render must NOT add the head yaw a second time: in VR the eye is composed as
// "the game's own view yaw, plus the head's pitch and roll". That one decision buys
// teleports, spawn re-orientation and prediction for free — the server's `delta_angles`
// rotate the player and the camera follows, because the camera is reading the same number
// the server is answering.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <math.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"
#include "system/system.h"          // Sys_Milliseconds

#include "q2_vr_glue.h"

extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a] Com_Printf, never the notify feed

extern void  Q2_VR_Log(const char *msg);
extern void  Q2_VR_BlackBoxPin(const char *key, const char *line);
extern float Q2_VR_WorldScale(void);
extern int   Q2_VR_Mode(void);
extern void  VID_iOS_AnalogMove(float forward, float side);
extern void  Q2_iOS_AutoPauseRelease(void);
extern bool  Q2_iOS_AutoPauseHeld(void);

// q2_vr_hands.m — the R4 consumer. Declared here rather than in a header because each of
// these is read at exactly one site in this file, and a header would invite a second reader
// that samples half of the set.
extern int   Q2_VR_HandsWorldFrame(const void *pose, float headYaw, float headPitch);
extern void  Q2_VR_HandsWorldIdle(void);
extern int   Q2_VR_HandsAimActive(void);
extern float Q2_VR_HandsAimYaw(void);
extern float Q2_VR_HandsAimPitch(void);
extern float Q2_VR_HandsMoveYaw(float headYaw, float sentRelYaw, int *rotate);
extern void  Q2_VR_HandsPublishViewmodel(void);
extern void  Q2_VR_RegisterHandCommands(void);
extern const void *Q2_VR_AcquiredPose(void);   // q2_vr_glue.m: this frame's acquired pair

// Q2's standing eye: viewheight 22 + |mins.z| 24. Derived, not guessed — p_move.cpp computes
// `pm->s.viewheight - pm->mins[2]` = 46 for the standing case, which is the arithmetic proof.
#define Q2_EYE_UNITS   46.0f

// q2repro has no AngleMod (Quake 1 and quake3e do); one line here rather than an engine
// patch for a helper, because a patch that exists only to add a convenience is a patch that
// makes the next upstream bump harder for nothing.
static float vr_anglemod(float a)
{
    a = fmodf(a, 360.0f);
    if (a > 180.0f) a -= 360.0f;
    if (a < -180.0f) a += 360.0f;
    return a;
}

// =====================================================================================
// The merged pad snapshot
// =====================================================================================
// ONE snapshot and ONE edge detector, per guide 4.3: the real pad driver and the synthetic
// `q2vrpad` injection write the SAME struct, so a simulator run exercises the code the
// headset will run rather than a parallel path beside it. Written from the main queue (the
// pad driver) and from the engine thread (the console injection); read on the engine thread.
// A mutex rather than atomics because the four axes are a SET — a turn computed from this
// frame's X against last frame's Y is a bug nobody would ever find.

// R4 — TWO SOURCES, ONE SNAPSHOT. The gamepad and the Sense pair are separate WRITERS into
// the same set, merged at READ time by larger magnitude per axis. Merging at read rather than
// letting the last writer win matters because the two producers run on different clocks (the
// 90 Hz pad timer and the compositor frame): last-writer-wins would make a held gamepad stick
// flicker to zero on every frame the hands also reported, which is a class of bug that looks
// like a hardware fault and is not one. A source that stops reporting clears its own slot, so
// putting a controller down does not leave its last deflection standing forever.

static pthread_mutex_t pad_lock = PTHREAD_MUTEX_INITIALIZER;
enum { Q2VR_STICK_PAD = 0, Q2VR_STICK_HAND = 1, Q2VR_STICK_SOURCES = 2 };
static struct {
    float lx, ly, rx, ry;
    int   present;          // a pad (or an injection) has been seen
    int   injected;         // the last write came from q2vrpad
} pad_src[Q2VR_STICK_SOURCES];

static float q2_pick(float a, float b) { return fabsf(a) >= fabsf(b) ? a : b; }

// The merged read. Callers hold `pad_lock`.
static void pad_merged_locked(float *lx, float *ly, float *rx, float *ry,
                              int *present, int *injected)
{
    float l0 = 0, l1 = 0, r0 = 0, r1 = 0;
    int p = 0, inj = 0;
    for (int i = 0; i < Q2VR_STICK_SOURCES; i++) {
        if (!pad_src[i].present) continue;
        p = 1;
        inj |= pad_src[i].injected;
        l0 = q2_pick(l0, pad_src[i].lx); l1 = q2_pick(l1, pad_src[i].ly);
        r0 = q2_pick(r0, pad_src[i].rx); r1 = q2_pick(r1, pad_src[i].ry);
    }
    if (lx) *lx = l0; if (ly) *ly = l1;
    if (rx) *rx = r0; if (ry) *ry = r1;
    if (present) *present = p;
    if (injected) *injected = inj;
}

void Q2_VR_PadStickSource(int source, float lx, float ly, float rx, float ry, int on)
{
    if (source < 0 || source >= Q2VR_STICK_SOURCES) return;
    pthread_mutex_lock(&pad_lock);
    if (on) {
        pad_src[source].lx = lx; pad_src[source].ly = ly;
        pad_src[source].rx = rx; pad_src[source].ry = ry;
        pad_src[source].present = 1;
    } else {
        memset(&pad_src[source], 0, sizeof(pad_src[source]));
    }
    pthread_mutex_unlock(&pad_lock);
}

void Q2_VR_PadSticks(float lx, float ly, float rx, float ry, int injected)
{
    pthread_mutex_lock(&pad_lock);
    // AN IDLE PHYSICAL PAD MUST NOT ERASE AN INJECTED SNAPSHOT. The pad driver writes this
    // slot at 90 Hz whether or not anything moved, so on a simulator — where a virtual
    // gamepad enumerates and its sticks sit at centre forever — `q2vrpad 0 1 0 0` was
    // overwritten with zeros within eleven milliseconds. The dump said so plainly
    // (`padinj=0 padL=(0.00,0.00)` immediately after an injection) and it made one R2 case
    // fail intermittently for a reason that had nothing to do with what it was testing.
    //
    // A real deflection still takes the slot back immediately, which is the behaviour that
    // matters: the injection is a stand-in for a pad, not a lock on one.
    if (!injected && pad_src[Q2VR_STICK_PAD].injected &&
        fabsf(lx) < 0.02f && fabsf(ly) < 0.02f && fabsf(rx) < 0.02f && fabsf(ry) < 0.02f) {
        pthread_mutex_unlock(&pad_lock);
        return;
    }
    pad_src[Q2VR_STICK_PAD].lx = lx; pad_src[Q2VR_STICK_PAD].ly = ly;
    pad_src[Q2VR_STICK_PAD].rx = rx; pad_src[Q2VR_STICK_PAD].ry = ry;
    pad_src[Q2VR_STICK_PAD].present = 1;
    pad_src[Q2VR_STICK_PAD].injected = injected;
    pthread_mutex_unlock(&pad_lock);
}

void Q2_VR_PadClear(void)
{
    pthread_mutex_lock(&pad_lock);
    memset(pad_src, 0, sizeof(pad_src));
    pthread_mutex_unlock(&pad_lock);
}

// A pad disappearing must clear only ITS slot — the hands are a separate writer on a
// separate clock, and zeroing their live deflection here reads as a stick glitch that
// has nothing to do with the pad (R4 review finding).
void Q2_VR_PadClearPad(void)
{
    pthread_mutex_lock(&pad_lock);
    memset(&pad_src[Q2VR_STICK_PAD], 0, sizeof(pad_src[Q2VR_STICK_PAD]));
    pthread_mutex_unlock(&pad_lock);
}

// =====================================================================================
// Body yaw, turning, movement direction
// =====================================================================================
// THE ALIGNMENT LOCK (R2.1). Exactly the same argument as the pad's mutex above, and for
// exactly the same reason: this is a SET, and it is written from TWO threads. The engine
// thread turns the body with the stick and seeds it from the game's view yaw; the RENDER
// thread folds an absorbed head yaw into it from `Q2_VR_NoteRecenter` (the recentre's two
// halves must happen in one breath, and the compositor owns the half that captures the
// base) and captures the standing height from `Q2_VR_NoteHeadHeight`. A recentre landing
// between the engine's read-modify-write of the body yaw is silently swallowed, and the
// player's world turns under them by the amount that was dropped.
//
// The rule for this lock, as for the pad's: hold it across ARITHMETIC ONLY. Every log line
// and black-box pin below is emitted from a snapshot taken under the lock and printed
// after it is released — Com_Printf reaches a file and a socket, and neither belongs
// inside a lock a render thread wants sixty times a second.

static pthread_mutex_t align_lock = PTHREAD_MUTEX_INITIALIZER;

static float vr_body_yaw;           // degrees; the yaw the STICK owns. The head adds to it.
static int   vr_body_seeded;        // seeded from the game's own view yaw, never from 0
static int   vr_recenters;          // BODYNOW reports this; the suite asserts it moves by 1
static float vr_pitch_trim;         // degrees, settings row in R4

// vkQuake's play-tested defaults. Snap is the default because smooth turning on a gamepad is
// the single most reliable way to make a new player put the headset down.
static int   vr_snap = 0;               // R9: Smooth is the shipped default
static float vr_snap_step = 30.0f;      // degrees per flick
static float vr_turn_speed = 140.0f;    // degrees per second, smooth mode
static int   vr_turn_armed = 1;         // hysteresis: fire above 0.6, RE-ARM below 0.4
static int   vr_turns;                  // how many snap turns have fired (assertable)

// 0 = head (default; the sent angles already ARE the head's, so the rotation is zero by
// construction), 1 = body (the stick's yaw, so strafing is relative to your torso and looking
// around does not steer). 2/3 are the aim-hand and off-hand modes; they need a tracked hand
// and are R4, so they resolve to head until then rather than silently doing something else.
static int   vr_movedir;

// The settings-row values that no engine code consumes YET (the hands round does), stored
// here anyway so the row is real from the day it appears: a settings row that stores nothing
// is a row the player sets, leaves, comes back to, and finds reset — and the migration
// machinery has nothing to migrate. Identity, not intent: the dumps report what is stored.
static int   vr_aim_hand = 1;       // 0 = left, 1 = right (charter D11 default: Right)
static int   vr_crosshair = 1;      // world-space aim dot, wired to the ray in R4
// R9 — the crosshair's ANGULAR size, as a multiple of the shipped 1.2-degree cross. It lives
// beside vr_crosshair because it is the same row's other half, and the engine reads it through
// Q2_VR_CrosshairSize() rather than keeping a second copy (the R4 rule, one line down).
static float vr_crosshair_size = 1.0f;
// R8: the ROW value, in the rescaled unit — NOT the engine multiplier. See
// Q2_VR_WeaponSizeToScale below: 0.5 .. 3.0, and 1.0 is the shipped gun.
static float vr_weapon_size = 1.0f; // row units, 0.5 .. 3.0
static int   vr_haptics = 1;
static int   vr_hud_pos = 1;        // 0 = High, 1 = Low, 2 = Off  (charter D11 default: Low)

// R7b item 8 — HUD Size and HUD Height. Second headset verdict: "HUD is WAY too small",
// with raise/lower and enlarge asked for "like we did in q3".
//
// THE TWO ARE APPLIED IN DIFFERENT PLACES, AND THAT IS THE WHOLE DESIGN.
//
//   * SIZE re-derives the engine's HUD SCALE inside the 2D-redirect bracket, so the layout is
//     recomposed at the new scale and the glyphs are drawn larger. It is NOT a transform on
//     the quad: magnifying the finished texture would make a HUD that is bigger and blurrier,
//     which on a headset — where the quad is already resampled twice — is the wrong trade
//     twice over. The Q3 port took the other road (it scales the QUAD's angular extent) only
//     because its HUD is carved into three separate world-space bands whose source rects it
//     cannot re-lay-out; this port composes one HUD into one sub-rect and can.
//   * HEIGHT moves the QUAD, because that is what "raise or lower the HUD" means and there is
//     nothing to re-lay-out for it. It is a trim ADDED to the High/Low preset, so the picker
//     still chooses the neighbourhood and the slider chooses the spot.
//
// Bounds mirror the sheet's, and the clamps are here rather than only there because the
// console command writes the same two values.
//
// R8 — THE ROW'S UNIT IS NOT THE ENGINE'S MULTIPLIER ANY MORE. The third headset verdict on
// 1.0.11.10: "HUD size is too small. The 3.0x should be the MINIMUM." The row was 0.75..3.0
// with the engine multiplier stored directly, so the top of the slider was the bottom of the
// useful range. Rather than ship a row whose numbers all read wrong (a "3.0x" that is the
// smallest setting), the row is rescaled: 1.0 on the row IS the old 3.5 multiplier, so the
// default reads 1.0x again and 0.85 (old 3.0) is the FLOOR he asked for.
//
// THE CEILING IS PHYSICS, NOT TASTE, and it is not the 2.0 the ask wanted. The engine lays
// the status bar out as a FIXED 320-unit-wide strip centred in the virtual screen, and the
// virtual screen is `hud_rect_width * R_ClampScale(scr_scale) / mul`. At the shipped VR
// Render Quality the HUD rect is 4800 px wide and the auto scale step is 4, so the virtual
// screen is 1200/mul units across and the strip stops fitting at mul = 3.75 — row 1.07.
// Measured, not derived: at row 1.07 the drawn HUD's bounding box touches x=4799 exactly, at
// 1.15 it touches x=0 as well, and by 1.50 the health digits and the weapon icon are half
// gone (R8 sim run, artifacts/vr-r5/hud-scale-sweep).
//
// R8 FOLLOW-UP — THE HYBRID, because "at least twice the old 3.0" is a real ask and the
// layout cannot answer it. The row now runs to 2.0 and TWO mechanisms share it:
//
//   * up to VR_HUD_LAYOUT_CAP the row is a LAYOUT multiplier, exactly as before: the HUD is
//     recomposed at a larger scale, so it is bigger AND sharp. This is the good mechanism and
//     it is used for as much of the range as it can carry.
//   * above the cap the layout multiplier stops moving and the surplus becomes MAGNIFICATION
//     of the finished quad — the Q3 port's mechanism — applied by the compositor to the HUD
//     quad's angular extent. It is a zoom of an already-resampled texture, so it is softer;
//     that is stated in the row's caption rather than hidden, and it is strictly better than
//     the alternative, which is a HUD whose top half draws a broken readout.
//
// Two accessors, and the split lives here and nowhere else: Q2_VR_HudSize is the ENGINE
// multiplier (capped) and Q2_VR_HudMagnify is the compositor's extent scale (1.0 until the
// cap, ~1.90 at row 2.0). Their product is the row, which is the invariant to check when
// either one moves.
// One constant does the conversion, in Q2_VR_HudSize, and every other site talks in ROW units.
#define VR_HUD_SIZE_UNIT   3.5f     // engine multiplier at row 1.0
#define VR_HUD_SIZE_MIN    0.85f    // ~ the old 3.0 maximum
#define VR_HUD_SIZE_MAX    2.0f     // the ROW's ceiling; past the layout cap it magnifies
#define VR_HUD_LAYOUT_CAP  1.05f    // mul 3.67; the layout clips at 1.07 (mul 3.75)
// The console rig's OWN ceiling, and it is deliberately past the row's. `q2vrhud` is the
// instrument the row's range was MEASURED with, and an instrument that cannot cross the limit
// it is measuring cannot re-measure it. (The LAYOUT cap is now enforced inside Q2_VR_HudSize,
// so driving the rig past it magnifies rather than clips — the clipping evidence for the cap
// itself is the recorded sweep in artifacts/vr-r5/hud-scale-sweep.)
#define VR_HUD_SIZE_DEVMAX 3.0f
// R23 — HUD SPREAD, the third row, and it is the one asked for by name: "make the HUD
// square bigger so that the bottom elements are further from their top elements but without
// making the hud elements bigger."
//
// The mechanism falls straight out of the two above. `scr.hud_scale` is a RECIPROCAL — the
// engine ORTHOS the 2D layer to `r_config.width * hud_scale` VIRTUAL units and lays every
// element out at a FIXED size in those units (a status-bar character is 8 of them). So the
// angular size of one character is
//
//      char_deg  =  8 / virtual_width  x  quad_deg
//
// and the two factors are separately reachable: the layout multiplier divides the virtual
// width (SCR_HudScaleChanged, overlay 0029), and the extent scale multiplies the quad. Spread
// moves BOTH by the same factor in OPPOSITE directions:
//
//      virtual width  x= spread      (layout multiplier /= spread)
//      quad extent    x= spread
//
// so char_deg is unchanged at every spread, while the canvas the elements are anchored to —
// status bar at the bottom, notify/centerprint at the top — is `spread` times taller and
// wider in ANGLE. Same font, same health digits, further apart. Exactly the ask.
//
// THE COMPOSITION, in one place (this is the comment block the round asked for):
//
//      Q2_VR_HudSize()    = min(row, LAYOUT_CAP) * SIZE_UNIT / spread   -> the engine
//      Q2_VR_HudMagnify() = row / min(row, LAYOUT_CAP) * spread         -> the compositor
//      product            = row * SIZE_UNIT                             -> INVARIANT in spread
//
// The product is the element's angular size and Spread does not appear in it — which is the
// one property a reader or a suite case can check without knowing which mechanism carries
// which share. HUD Size keeps both of its jobs unchanged (layout below the cap, quad
// magnification above it) and Spread composes multiplicatively with each.
//
// NO NEW TEXTURE, and this is why the row is cheap: the UI surface is a fixed eye-sized
// texture and the HUD's sub-rect (s_hudW x s_hudH, xr3_glue.m) does not move. Only the
// VIRTUAL-to-pixel scale changes, so a larger canvas costs zero bytes and zero draws — the
// HUD is simply rasterised smaller into the same pixels and then shown on a larger quad.
// Spread can never CLIP either: the 320-unit status strip has to fit in the virtual width,
// and Spread only ever makes that width larger. It is the one direction the layout is safe in.
#define VR_HUD_SPREAD_MIN  1.0f     // 1.0 = today's canvas, exactly
#define VR_HUD_SPREAD_MAX  2.0f     // the canvas is twice as wide and twice as tall, in angle
// R11 — WHICH EYE HOSTS THE 2D REDIRECT. 0 = eye 0 (the shipped behaviour), 1 = eye 1,
// 2 = neither: a pass of its own after both eyes (overlay 0036's `ui_only`).
//
// [R12] STILL AN INSTRUMENT, still default 0. A first headset A/B read mode 2 as "much
// better", but the controlled repeat — same slow turn, same edge — read mode 0 as
// "constant in both eyes" and mode 2 as "constant in the left, occasional in the right",
// i.e. no better than shipped. The first reading was transient. The default therefore does
// not move, and the modes stay available for the next A/B.
//
// This is an INSTRUMENT, not a player-facing row: it exists because the redirect running
// inside eye 0's render is the last structural left/right asymmetry in the pipeline, and
// the Vision Pro reports a constant LEFT-eye jitter that anchor lag, ring-slot
// collisions, frustum drift, render quality and sharpening have all been measured innocent
// of. Mode 1 is the decisive A/B — if the jitter moves to the right eye, the redirect is the
// mechanism — and mode 2 is the shape the fix would take. Console-only (`q2vrset vr_ui_eye`),
// no sheet row: a setting that only makes sense while an experiment is running does not
// belong in front of a player.
static int   vr_ui_eye     = 0;
// [R24] The three HUD defaults are the 1.0.11.27 verdict: 1.20 / -0.20 / 1.4. These
// fallbacks and the Swift @AppStorage defaults (Q2VRDefaults) must move together — an
// untouched row has NO stored value, so the code default IS the shipped setting on both
// sides, and stamp 6's migration only drops stores that still carry the OLD default.
static float vr_hud_size   = 1.20f;     // ROW units (x VR_HUD_SIZE_UNIT = engine multiplier)
static float vr_hud_height = -0.20f;    // metres, added to the High/Low anchor (R24 default)
static float vr_hud_spread = 1.4f;      // R23: canvas multiplier; element size is invariant

// The compositor reads these two every frame. HUD Position is the "HUD customization" ask
// from the first headset round: it moves the head-locked quad's vertical anchor, and Off
// suppresses the HUD without touching menus or the console (those are PANEL frames and go
// through a different surface entirely, which is why one control can do both jobs safely).
float Q2_VR_UIHeightOffset(void)
{
    return (vr_hud_pos == 0 ? 0.18f : -0.26f) + vr_hud_height;
}
// Read on the ENGINE thread, inside the 2D-redirect bracket. Not cached through the settings
// generation for the same reason Sharpen is not: it is consumed at one site, once a frame, and
// a slider the player is dragging should resize under their hands.
// Returns the ENGINE MULTIPLIER (what SCR_HudScaleChanged wants), converted from the row
// here and nowhere else — and CAPPED, because past VR_HUD_LAYOUT_CAP the layout stops fitting
// and a larger multiplier draws less HUD, not more.
// R23: ...and DIVIDED by Spread, which is the whole of that row on this side — a smaller
// layout multiplier is a LARGER virtual canvas (hud_scale is a reciprocal), and the quad grows
// by the same factor below, so the elements keep their angular size and only move apart.
float Q2_VR_HudSize(void)
{
    return min(vr_hud_size, VR_HUD_LAYOUT_CAP) * VR_HUD_SIZE_UNIT / vr_hud_spread;
}
// ...and the surplus the layout refused, as a multiplier on the HUD quad's angular extent.
// Written as row / min(row, cap) rather than as row - cap so that the two accessors MULTIPLY
// back to the row exactly: Q2_VR_HudSize() * Q2_VR_HudMagnify() == row * VR_HUD_SIZE_UNIT for
// every row, which is the one property a reader (or a suite case) can check without knowing
// which mechanism is carrying which part of it.
// R23: times Spread, the other half of the same identity. Every consumer of this accessor is
// a place that sizes the HUD QUAD — the compositor's extents (VRShell) and the wheel ray's
// copy of them (q2_vr_hands) — which is exactly the set that has to grow with the canvas, so
// Spread rides this accessor rather than adding a third one every call site must remember.
float Q2_VR_HudMagnify(void)
{
    return vr_hud_size / min(vr_hud_size, VR_HUD_LAYOUT_CAP) * vr_hud_spread;
}
float Q2_VR_HudSizeRow(void) { return vr_hud_size; }
float Q2_VR_HudSpread(void)  { return vr_hud_spread; }
// Read straight from the store by the compositor thread, not cached through the generation:
// this one is a Metal-side value with no engine state behind it, and a slider the player is
// dragging should sharpen under their hands.
float Q2_VR_Sharpen(void)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    float s = [d objectForKey:@"vr_sharpen"] ? (float)[d floatForKey:@"vr_sharpen"] : 0.5f;
    return s < 0.0f ? 0.0f : (s > 1.0f ? 1.0f : s);
}
// R13 — THE WHEEL MIRROR. `CL_iOS_WheelOpen` is client state on the ENGINE thread; the
// compositor needs it every frame on its own thread, so the world frame mirrors it into an
// atomic here (the shape the R7a snapshot rules ask for).
static atomic_int vr_wheel_open;
void  Q2_VR_NoteWheelOpen(int open)  { atomic_store(&vr_wheel_open, open); }
int   Q2_VR_WheelOpenMirror(void)    { return atomic_load(&vr_wheel_open); }
// HUD Position "Off" must not take the WHEEL away with the health bar. Off passes nil for the
// UI texture, so with a wheel open and this false nothing 2D is composited at all — the wheel
// opens, holsters the gun and is invisible, which is indistinguishable from broken. The row
// still means what it says the rest of the time.
int   Q2_VR_UIVisible(void)      { return vr_hud_pos != 2 || atomic_load(&vr_wheel_open) != 0; }
// R11 — read on the ENGINE thread once per eye, inside vr_apply_eye. Plain int, written once
// per settings generation on the same thread, exactly as every other row here.
int   Q2_VR_UIEye(void)          { return vr_ui_eye; }
// R4: the store is read here and only here; q2_vr_hands.m asks rather than keeping a second
// copy, so a row that stops being applied stops being applied in ONE place.
int   Q2_VR_AimHandSetting(void)    { return vr_aim_hand; }
int   Q2_VR_CrosshairSetting(void)  { return vr_crosshair; }
float Q2_VR_CrosshairSize(void)     { return vr_crosshair_size; }
// R8 — WEAPON SIZE'S ROW UNIT IS NOT THE ENGINE MULTIPLIER EITHER, and for the mirror of the
// HUD's reason. The third headset verdict: the gun wanted is the old 0.8, the biggest wanted
// is the old 1.6, and the row should call the first of those 1.0x. A linear remap would put
// that max at 2.0x, which is not what "a much bigger number like 3.0x" asks for; a POWER map
// gives him the endpoints he named and a slider that is finer where he lives.
//
//   engine = 0.8 * row^0.631      row 1.0 -> 0.800   (the shipped gun)
//                                 row 3.0 -> 1.600   (his stated maximum)
//                                 row 0.5 -> 0.517   (about the old minimum)
//
// 0.631 = ln(2)/ln(3), which is exactly what makes row 3 land on twice row 1. The inverse
// exponent (1.585) is the migration's, and it is written down beside it in VisionShell.swift.
#define VR_WEAPON_SIZE_BASE  0.8f
#define VR_WEAPON_SIZE_EXP   0.631f
float Q2_VR_WeaponSizeToScale(float row)
{
    if (!(row > 0.0f)) row = 1.0f;
    return VR_WEAPON_SIZE_BASE * powf(row, VR_WEAPON_SIZE_EXP);
}
// The ENGINE MULTIPLIER — this is what feeds q2vr.weapon_scale, so the mapping is applied on
// the one path that reaches the renderer.
float Q2_VR_WeaponSizeSetting(void) { return Q2_VR_WeaponSizeToScale(vr_weapon_size); }
float Q2_VR_WeaponSizeRow(void)     { return vr_weapon_size; }
int   Q2_VR_HapticsSetting(void)    { return vr_haptics; }
float Q2_VR_PitchTrim(void)         { return vr_pitch_trim; }
int   Q2_VR_MoveDirMode(void)       { return vr_movedir; }

static const char *vr_movedir_name(void)
{
    switch (vr_movedir) {
    case 1: return "body";
    case 2: return "aimhand";
    case 3: return "offhand";
    default: return "head";
    }
}

// =====================================================================================
// Height (charter D7, guide 12.5)
// =====================================================================================
// The DEVIATION form, and only the deviation form. `standing_eye_m * ws - 46` is right at
// ws = 39.37 and quietly wrong everywhere else, because it ties the player's stature IN
// UNITS to a slider whose job is to size the world. What we convert is how far this person
// differs from the stature the engine's own 46-unit constant already represents.
//
// The baseline is captured ONCE and sanity-gated, because the alignment is re-derived on
// every recentre and a player who recentred while seated became permanently short on a donor.

#define VR_HEIGHT_MIN_M  0.6f
#define VR_HEIGHT_MAX_M  2.6f
#define VR_HEIGHT_FALLBACK_M 1.65f

static float vr_height_baseline_m;      // 0 = not captured
static float vr_height_trim_m;          // +-0.5 m, the player's own nudge
static int   vr_height_rejected;        // a capture that failed the gate (diagnostic)

// Called every frame from the compositor with the head's height in the tracking frame.
// visionOS does not hand an app a floor plane, so this number is only as floor-referenced as
// the world origin happens to be; the sanity gate is therefore doing real work, not
// paperwork, and a rejected capture falls back to a stature rather than to nonsense.
// RENDER THREAD. Everything it touches is under `align_lock`; the logging is done from a
// snapshot, outside it.
void Q2_VR_NoteHeadHeight(float metres)
{
    int captured = 0, rejected = 0;
    pthread_mutex_lock(&align_lock);
    if (vr_height_baseline_m > 0.0f) {
        pthread_mutex_unlock(&align_lock);
        return;
    }
    if (metres > VR_HEIGHT_MIN_M && metres < VR_HEIGHT_MAX_M) {
        vr_height_baseline_m = metres;
        captured = 1;
    } else if (!vr_height_rejected) {
        vr_height_rejected = 1;
        rejected = 1;
    }
    pthread_mutex_unlock(&align_lock);

    if (captured) {
        char line[128];
        Q_snprintf(line, sizeof(line), "VRHEIGHT baseline=%.3fm source=tracking gate=passed", metres);
        Q2_VR_BlackBoxPin("height", line);
        Q2_VR_Log(line);
    } else if (rejected) {
        char line[160];
        Q_snprintf(line, sizeof(line),
                   "VRHEIGHT baseline=%.3fm REJECTED (outside %.1f-%.1fm) using %.2fm",
                   metres, VR_HEIGHT_MIN_M, VR_HEIGHT_MAX_M, VR_HEIGHT_FALLBACK_M);
        Q2_VR_BlackBoxPin("height", line);
        Q2_VR_Log(line);
    }
}

// `_locked` in the name means the CALLER already holds `align_lock`. There is deliberately
// no self-locking variant: every caller needs several of these values together anyway, so
// each takes the lock once around the whole read. A self-locking helper would also be the
// easy way to re-enter the lock from the frame path, and a default pthread mutex deadlocks
// on that rather than telling you.
static float vr_standing_eye_m_locked(void)
{
    float h = vr_height_baseline_m > 0.0f ? vr_height_baseline_m : VR_HEIGHT_FALLBACK_M;
    return h + vr_height_trim_m;
}

// rise = (standing_eye_m - 46/ws) * ws.  At ws = 34 and a 1.73 m player that is +12.8 u.
static float vr_rise_units_locked(void)
{
    float ws = Q2_VR_WorldScale();
    if (ws < 1.0f) ws = 1.0f;
    float rise = (vr_standing_eye_m_locked() - Q2_EYE_UNITS / ws) * ws;
    return Q_clipf(rise, -40.0f, 120.0f);
}

// =====================================================================================
// Recentre — ONE function owning the yaw-only base
// =====================================================================================
// The base itself is captured on the compositor side, because that is where the anchor is;
// what lives here is the other half of the same operation, and the two are called from one
// place each so the pair cannot drift. Recentring must NOT swing the view: the head yaw that
// is about to be zeroed is added into the body yaw in the same breath.

static atomic_int vr_recenter_req;

void Q2_VR_RequestRecenter(void) { atomic_store(&vr_recenter_req, 1); }
int  Q2_VR_ConsumeRecenterRequest(void)
{
    int want = atomic_exchange(&vr_recenter_req, 0);
    return want;
}

// Compositor -> here, immediately after it re-captures the yaw-only base. `headYawDeg` is the
// yaw that has just been folded into the base and will therefore read as 0 next frame.
// RENDER THREAD. `vr_body_yaw` is read-modify-written here and in the engine thread's
// turning step, so the whole update is one critical section and the log line is printed
// from the snapshot it leaves behind.
void Q2_VR_NoteRecenter(float headYawDeg)
{
    float yaw; int n;
    pthread_mutex_lock(&align_lock);
    vr_body_yaw = vr_anglemod(vr_body_yaw + headYawDeg);
    vr_recenters++;
    yaw = vr_body_yaw; n = vr_recenters;
    pthread_mutex_unlock(&align_lock);

    char line[128];
    Q_snprintf(line, sizeof(line), "VRRECENTER n=%d absorbed=%.1fdeg bodyyaw=%.1fdeg",
               n, headYawDeg, yaw);
    Q2_VR_BlackBoxPin("recenter", line);
    Q2_VR_Log(line);
}

// =====================================================================================
// The body yaw, published to the render composition (R3)
// =====================================================================================
// THE WHOLE POINT OF THIS ACCESSOR. Until R3 the rendered yaw was the GAME'S view yaw
// (q2vr.yaw_relative added cl.refdef.viewangles[YAW] at the view.c site). That number comes
// out of the client simulation, which does not advance on every rendered frame, so the
// camera's yaw lagged the head pose the compositor was reprojecting against — and the
// residual, which is non-zero only while the head turns, was the look jitter.
//
// Now the render composes body + head itself, from values that are both fresh this frame,
// and the only engine term left is the server's own re-orientation. This is the body half.
// Engine thread, called from vr_apply_eye AFTER Q2_VR_InputFrame has run for this frame.
float Q2_VR_BodyYaw(void)
{
    float y;
    pthread_mutex_lock(&align_lock);
    y = vr_body_yaw;
    pthread_mutex_unlock(&align_lock);
    return y;
}

// =====================================================================================
// The settings section (charter D11), applied from the store
// =====================================================================================
// The SwiftUI sheet stores; this applies. One generation counter rather than a call per row:
// the sheet is a MainActor view and every engine-touching call from it would have to go
// through the producer funnel, whereas one integer read at the top of the engine frame is
// cheaper than the funnel hop and cannot arrive out of order with the values it describes.
// The sheet bumps `vr_gen` LAST, after every value it changed is stored, so a generation the
// engine observes always describes a store that is already complete.
//
// Rows the engine cannot honour yet (aim hand, weapon size, haptics, crosshair) are stored
// and reported all the same — see the note beside their statics.

static int vr_settings_gen = -1;

static float vr_pref_f(NSUserDefaults *d, NSString *k, float def)
{
    return [d objectForKey:k] ? (float)[d floatForKey:k] : def;
}

void Q2_VR_ApplySettings(int force)
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    int gen = (int)[d integerForKey:@"vr_gen"];
    if (!force && gen == vr_settings_gen) return;
    vr_settings_gen = gen;

    // Snap Turn: Smooth / 30 / 45 / 60. The stored value IS the step in degrees, with 0
    // meaning smooth, so the row's label and the engine's number are the same thing and
    // there is no table to keep in step. R9 defaults it to Smooth (0) — the fourth
    // headset verdict; the fallback here must match Q2VRDefaults.snapStep.
    float step = vr_pref_f(d, @"vr_snapstep", 0.0f);
    vr_snap = step > 0.5f;
    if (vr_snap) vr_snap_step = Q_clipf(step, 5.0f, 90.0f);
    vr_turn_armed = 1;
    vr_turn_speed = Q_clipf(vr_pref_f(d, @"vr_turnspeed", 160.0f), 60.0f, 260.0f);

    // Movement Direction. The row offers Head / Aim Hand / Off Hand (charter D11); the
    // engine's internal 1 is the console-only `body` mode, which the row does not expose and
    // the suite still drives. 2 and 3 resolve to head until a tracked hand exists.
    int md = (int)[d integerForKey:@"vr_movedir"];
    vr_movedir = (md == 2 || md == 3) ? md : 0;

    vr_pitch_trim = Q_clipf(vr_pref_f(d, @"vr_pitchtrim", 0.0f), -15.0f, 15.0f);

    pthread_mutex_lock(&align_lock);
    vr_height_trim_m = Q_clipf(vr_pref_f(d, @"vr_heighttrim", 0.0f), -0.5f, 0.5f);
    pthread_mutex_unlock(&align_lock);

    vr_aim_hand    = [d objectForKey:@"vr_aimhand"] ? (int)[d integerForKey:@"vr_aimhand"] : 1;
    vr_crosshair   = [d objectForKey:@"vr_crosshair"] ? ([d boolForKey:@"vr_crosshair"] ? 1 : 0) : 1;
    vr_crosshair_size = Q_clipf(vr_pref_f(d, @"vr_crosshairsize", 1.0f), 0.5f, 3.0f);
    vr_weapon_size = Q_clipf(vr_pref_f(d, @"vr_weaponsize", 1.0f), 0.5f, 3.0f);
    vr_haptics     = [d objectForKey:@"vr_haptics"] ? ([d boolForKey:@"vr_haptics"] ? 1 : 0) : 1;
    vr_hud_pos     = [d objectForKey:@"vr_hudpos"] ? (int)[d integerForKey:@"vr_hudpos"] : 1;
    if (vr_hud_pos < 0 || vr_hud_pos > 2) vr_hud_pos = 1;
    vr_hud_size    = Q_clipf(vr_pref_f(d, @"vr_hudsize", 1.20f), VR_HUD_SIZE_MIN, VR_HUD_SIZE_MAX);
    vr_hud_height  = Q_clipf(vr_pref_f(d, @"vr_hudheight", -0.20f), -0.6f, 0.6f);
    vr_hud_spread  = Q_clipf(vr_pref_f(d, @"vr_hudspread", 1.4f),
                             VR_HUD_SPREAD_MIN, VR_HUD_SPREAD_MAX);
    {
        int was = vr_ui_eye;
        vr_ui_eye = [d objectForKey:@"vr_ui_eye"] ? (int)[d integerForKey:@"vr_ui_eye"] : 0;
        if (vr_ui_eye < 0 || vr_ui_eye > 2) vr_ui_eye = 0;
        // ONCE, on a CHANGE. The whole point of the row is a device A/B driven over the
        // console, and "which arrangement is on screen right now" has to be answerable from
        // the log without a dump — but a line every settings generation would bury it.
        if (vr_ui_eye != was) {
            char line[64];
            Q_snprintf(line, sizeof line, "VRUIEYE mode=%d", vr_ui_eye);
            Q2_VR_BlackBoxPin("uieye", line);
            Q2_VR_Log(line);
        }
    }

    // R8 — NO GRIP HERE ANY MORE. R7b's six rows were a tuning rig; they were dialled in the
    // headset and the answer is now the shipped constant in q2_vr_hands.m. The settings store
    // no longer carries vr_grip* at all (stamp 2 force-deletes the keys), so reading them here
    // would resurrect a value the migration just removed.
}

// Re-calibrate Height, from the row. Same body as `q2vrheight recal`, so the row and the
// console cannot drift; the Reset button calls it too, which is what "the VR Reset also
// clears the height baseline" means in practice.
void Q2_VR_ClearHeightBaseline(void)
{
    pthread_mutex_lock(&align_lock);
    vr_height_baseline_m = 0.0f;
    vr_height_rejected = 0;
    pthread_mutex_unlock(&align_lock);
    Q2_VR_Log("VRHEIGHT baseline cleared by the settings row");
}

// The VR rows, for SETTINGSNOW. Appended to that record, never inserted.
void Q2_VR_DumpSettingsFields(char *out, int outsz)
{
    float trim;
    pthread_mutex_lock(&align_lock);
    trim = vr_height_trim_m;
    pthread_mutex_unlock(&align_lock);
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    Q_snprintf(out, outsz,
               " vrgen=%d vrheighttrim=%.3fm vrquality=%.2f vrsharpen=%.2f vraimhand=%s "
               "vrmovedir=%s vrsnapstep=%.0fdeg vrturnspeed=%.0fdeg_per_s vrcrosshair=%d "
               "vrpitchtrim=%.1fdeg vrhudpos=%s vrweaponsize=%.2f vrwepmul=%.2f vrhaptics=%d "
               "vrcrosshairsize=%.2f "
               "vrhudsize=%.2f vrhudmul=%.2f vrhudmag=%.2f vrhudheight=%.2fm "
               "vrhudspread=%.2f "
               "vruieye=%d vrmig=%d vrmigdid=%s",
               vr_settings_gen, trim,
               vr_pref_f(d, @"vr_quality", 1.5f), vr_pref_f(d, @"vr_sharpen", 0.5f),
               vr_aim_hand ? "right" : "left", vr_movedir_name(),
               vr_snap ? vr_snap_step : 0.0f, vr_turn_speed, vr_crosshair,
               vr_pitch_trim,
               vr_hud_pos == 0 ? "high" : vr_hud_pos == 1 ? "low" : "off",
               vr_weapon_size, Q2_VR_WeaponSizeToScale(vr_weapon_size), vr_haptics,
               vr_crosshair_size,
               vr_hud_size, Q2_VR_HudSize(), Q2_VR_HudMagnify(), vr_hud_height,
               vr_hud_spread,
               vr_ui_eye, (int)[d integerForKey:@"vr_migration"],
               [d stringForKey:@"vr_migration_did"].UTF8String ?: "none");
}

// =====================================================================================
// The per-frame input step
// =====================================================================================
// Runs at the top of the engine frame, on the engine thread, AFTER the producer queue has
// been drained (so an injected stick set this frame is the stick this frame uses) and BEFORE
// Qcommon_Frame (so what it writes is what CL_UpdateCmd reads).

static double vr_last_ms;

void Q2_VR_InputFrame(float headYaw, float headPitch, int world, int poseValid)
{
    double now = Sys_Milliseconds();
    float dt = vr_last_ms > 0 ? (float)(now - vr_last_ms) * 0.001f : 0.0f;
    vr_last_ms = now;
    if (dt < 0.0f || dt > 0.25f) dt = 0.0f;     // a map load is not a second of turning

    // R4 — THE HANDS, FIRST. The Sense consumer runs before the pad snapshot is read because
    // it WRITES into that snapshot (its sticks are one source in the same merged set) and
    // because it is what decides whether this frame's aim is the head's or a hand's. The pose
    // it reads is the pair the engine acquired at the top of this frame, so the hands and the
    // head that reach every line below came out of ONE publish.
    if (!world || !poseValid) Q2_VR_HandsWorldIdle();
    else                      Q2_VR_HandsWorldFrame(Q2_VR_AcquiredPose(), headYaw, headPitch);

    // R13 — the wheel mirror, UNCONDITIONALLY and here rather than only inside the hands. A
    // gamepad player can open the wheel with RB, and the hands' world frame early-returns the
    // moment the pair stops answering; either way the compositor must not be left holding a
    // stale "a wheel is open" (HUD "Off" would keep compositing) or a stale "closed" (the wheel
    // would be invisible). One writer, every frame, whatever opened it.
    {
        extern int CL_iOS_WheelOpen(void);
        Q2_VR_NoteWheelOpen(CL_iOS_WheelOpen());
    }

    float lx, ly, rx;
    int present;
    pthread_mutex_lock(&pad_lock);
    pad_merged_locked(&lx, &ly, &rx, NULL, &present, NULL);
    pthread_mutex_unlock(&pad_lock);

    if (!world || !poseValid) {
        // Not a world frame: the panel owns input (menus and the console are ordinary key
        // events through the paths that already work). Clear the gate so nothing we wrote
        // last frame leaks into a frame that is not ours, and drop the seed so the next world
        // frame re-derives the body yaw from whatever the game is doing by then.
        q2vr.aim_valid = 0;
        q2vr.move_rotate = 0;
        q2vr.rise = 0.0f;
        pthread_mutex_lock(&align_lock);
        vr_body_seeded = 0;
        pthread_mutex_unlock(&align_lock);
        return;
    }

    // ONE critical section covers the seed, the turn and the reads that feed the gate, so a
    // recentre arriving from the render thread either lands entirely before this frame's
    // read-modify-write or entirely after it — never inside it, which is the shape that
    // loses an absorbed yaw and turns the player's world under them.
    float body_yaw, rise;
    int seeded_now = 0;
    float seed_view = 0.0f, seed_yaw = 0.0f;

    pthread_mutex_lock(&align_lock);

    // Seed the body yaw from the game's OWN view yaw, never from 0 (guide 12.5): forcing 0
    // drops the player into the level staring at a wall. `view_yaw_out` is what the client
    // last actually sent, so the seed subtracts the head to leave the body where it was.
    if (!vr_body_seeded) {
        vr_body_yaw = vr_anglemod(q2vr.view_yaw_out - headYaw);
        vr_body_seeded = 1;
        seeded_now = 1;
        seed_view = q2vr.view_yaw_out;
        seed_yaw = vr_body_yaw;
    }

    // ---- turning ---------------------------------------------------------------------
    // The stick writes the BODY yaw and nothing else. It never touches pitch: in VR the head
    // owns pitch absolutely, and a stick that could also pitch the camera is a stick that can
    // put the horizon somewhere the player's neck says it is not.
    if (present && fabsf(rx) > 0.0f) {
        if (vr_snap) {
            // Hysteresis, fire above 0.6 and RE-ARM below 0.4. A held stick is ONE turn, not
            // a turntable — the same shape that will serve stick-flick weapon cycling.
            if (!vr_turn_armed && fabsf(rx) < 0.4f)
                vr_turn_armed = 1;
            if (vr_turn_armed && fabsf(rx) > 0.6f) {
                vr_body_yaw = vr_anglemod(vr_body_yaw - (rx > 0 ? vr_snap_step : -vr_snap_step));
                vr_turn_armed = 0;
                vr_turns++;
            }
        } else if (fabsf(rx) > 0.15f) {
            vr_body_yaw = vr_anglemod(vr_body_yaw - rx * vr_turn_speed * dt);
        }
    } else if (!vr_snap) {
        /* nothing to do */
    } else if (present) {
        vr_turn_armed = 1;
    }

    body_yaw = vr_body_yaw;
    rise = vr_rise_units_locked();
    pthread_mutex_unlock(&align_lock);

    if (seeded_now) {
        char line[128];
        Q_snprintf(line, sizeof(line), "VRSEED bodyyaw=%.1fdeg from viewyaw=%.1fdeg head=%.1fdeg",
                   seed_yaw, seed_view, headYaw);
        Q2_VR_Log(line);
    }

    // ---- the auto-pause release (guide 10 #11) ----------------------------------------
    // R0's auto-pause is TRACKED — `pause` is a toggle, so only what WE paused may be
    // released. Tested on the finished usercmd rather than on one device's handler, so every
    // device counts: a stick, a fired button and a bound key all read the same way here.
    if (Q2_iOS_AutoPauseHeld()) {
        bool playing = (fabsf(lx) > 0.2f || fabsf(ly) > 0.2f || fabsf(rx) > 0.2f) ||
                       q2vr.move_out[0] != 0.0f || q2vr.move_out[1] != 0.0f;
        if (playing) Q2_iOS_AutoPauseRelease();
    }

    // ---- what the engine reads --------------------------------------------------------
    // R4 — THE AIM SOURCE. The hands module arbitrates (aim hand while posed, two frames of
    // hysteresis on loss only, immediate on acquire) and hands back ONE pair of angles; when
    // nothing is tracked it hands back the head's, which is byte-for-byte what R3 sent. That
    // is the no-regression contract: with no Sense pair connected this file behaves exactly
    // as it did, and the gamepad remains a fully functional aim source.
    const int   hand_aim = Q2_VR_HandsAimActive();
    const float rel_yaw  = hand_aim ? Q2_VR_HandsAimYaw()   : headYaw;
    const float aim_pitch = hand_aim ? Q2_VR_HandsAimPitch()
                                     : (headPitch + vr_pitch_trim);

    q2vr.aim_valid = 1;
    q2vr.aim_angles[PITCH] = Q_clipf(aim_pitch, -89.0f, 89.0f);
    q2vr.aim_angles[YAW]   = vr_anglemod(body_yaw + rel_yaw);
    q2vr.aim_angles[ROLL]  = 0.0f;

    // Movement direction, generalised (charter D5). `move_yaw` is "the yaw movement should be
    // relative to, minus the yaw being sent". Head mode was a zero rotation for the whole of
    // R2/R3 because the head WAS the aim source; with a hand aiming it stops being zero, and
    // that is precisely what turns Head / Aim Hand / Off Hand from three stored strings into
    // three different ways to walk. Body mode (console-only) is unchanged.
    if (vr_movedir == 1) {
        q2vr.move_yaw = -rel_yaw;
        q2vr.move_rotate = 1;
    } else {
        int rot = 0;
        q2vr.move_yaw = Q2_VR_HandsMoveYaw(headYaw, rel_yaw, &rot);
        q2vr.move_rotate = rot;
    }

    // The viewmodel mount, the aim dot and the pitch compensation, published once per host
    // frame from the same hand set the aim just came from.
    Q2_VR_HandsPublishViewmodel();

    q2vr.rise = rise;
    q2vr.ceiling_clamp = 1;
}

// =====================================================================================
// Crash-safe cvar stash (charter D9, guide 12.8)
// =====================================================================================
// VR overrides ARCHIVED cvars. A crash or a swipe-kill inside VR then writes those overrides
// into the player's own config PERMANENTLY — and the surface is not hypothetical here:
// `gl_shadows` is CVAR_ARCHIVE and VR entry sets it to 0 because ANGLE-Metal will not give us
// a stencil buffer beside a depth texture. A 2D player left with no shadows, forever, with no
// idea why, is exactly the donor bug this mechanism exists to prevent.
//
// Stash to the SETTINGS STORE, not a static: a static dies with the process, and the process
// dying is the case. On launch, a leftover stash is detected, restored, and the config is
// written IMMEDIATELY so the repair sticks even if the next thing that happens is another
// crash.

extern void CL_iOS_SetWheelAnchor(float ux, float uy);   // overlay 0015

static NSString * const kStashKey = @"vr_cvar_stash";

// Everything VR takes away from the player, with the value it takes. Adding a row here is the
// whole cost of stashing a new override.
static const struct { const char *name; const char *vrValue; } vr_overrides[] = {
    { "gl_shadows",      "0"   },   // CVAR_ARCHIVE. No stencil buffer in VR (D-VR-R1).
    { "gl_multisamples", "0"   },   // a multisampled depth buffer is not a valid snapshot
    { "viewsize",        "100" },   // CVAR_ARCHIVE. Anything else leaves a tile-clear border
    { "cl_predict",      "1"   },   // the VR camera reads cl.predicted_angles; without
                                    // prediction the head lags by a server frame
    // [R12] THE TWO THAT COST THE COMPOSITOR ITS DEPTH. gl_bloom and gl_waterwarp both make
    // GL_BindFramebuffer render the WORLD into the renderer's own FBO_SCENE, whose depth is
    // a private DEPTH24_STENCIL8 RENDERBUFFER (texture.c); only the COLOUR is then composited
    // into the eye framebuffer as a fullscreen quad with depth writes off. So the per-eye
    // Depth32Float texture we hand visionOS is never written by anything, and an
    // uninitialised private depth texture reads back as NaN — which the eye shader turns into
    // "the whole world is 12 cm from your face", and every head translation is then
    // reprojected against a plane. Measured on the simulator before this line existed:
    // `VRDEPTH ... zero%=100.00 ... gl_e0f=1 gl_e1f=1 gl_bloom=1 gl_waterwarp=1` — the
    // gl_e*f=1 is a GL-SIDE read of the same texture returning NaN, i.e. GL never wrote there;
    // ANGLE's EGLImage depth wrap was innocent all along (the R0 spike was right).
    //
    // The standalone visionOS-3D shell has always set both to 0 at boot (xr_boot.m); the
    // MERGED 2D+3D app excludes xr_boot.m, so VR inherited the defaults of 1 and has been
    // publishing dead depth since the merge. Setting them here rather than at boot keeps the
    // 2D panel build's bloom intact and gets the stash's restore-on-exit for free.
    //
    // The cost is bloom and underwater warp inside VR. Correct reprojection is worth more
    // than either; keeping both would mean attaching the eye's depth texture to FBO_SCENE
    // per eye, which is a bigger change and belongs in its own round.
    { "gl_bloom",        "0"   },
    { "gl_waterwarp",    "0"   },
    // [R23] PER-FACE DYNAMIC-LIGHT LISTS. Upstream batches a surface run under the UNION of
    // every dlight touching any face in the run, so one light near one face makes the whole
    // batch pay for it; overlay 0045's `gl_dlight_batchkey 1` breaks the batch when the face's
    // light set changes, trading a few more draw calls for a much smaller per-fragment light
    // loop. The controlled A/B in the headset (2026-09-07, artifacts/vr-r22/ab-headset.log)
    // measured engine GPU time 13 ms -> 9.8 ms for +1.4 ms CPU, with no shading artefacts in
    // play — a clear win on a GPU-bound stereo frame, which is why it is a VR default and not
    // an upstream one. Flat iOS/2D keeps upstream's 0: it is nowhere near GPU-bound there, so
    // the extra draw calls would be pure cost.
    //
    // NOT CVAR_ARCHIVE (refresh/main.c ~1365 registers it with flags 0), so unlike gl_shadows
    // it could never leak into the player's config — it rides this table purely to get the
    // same apply-on-entry / restore-on-exit lifetime as its neighbours.
    { "gl_dlight_batchkey", "1" },
};
#define VR_OVERRIDE_COUNT ((int)(sizeof(vr_overrides) / sizeof(vr_overrides[0])))

static int vr_stash_held;

void Q2_VR_StashCvars(void)
{
    if (vr_stash_held) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (int i = 0; i < VR_OVERRIDE_COUNT; i++) {
        cvar_t *c = Cvar_FindVar(vr_overrides[i].name);
        if (!c) continue;
        d[@(vr_overrides[i].name)] = @(c->string);
    }
    if (!d.count) return;
    [NSUserDefaults.standardUserDefaults setObject:d forKey:kStashKey];
    [NSUserDefaults.standardUserDefaults synchronize];   // the case is the process dying
    vr_stash_held = 1;
    for (int i = 0; i < VR_OVERRIDE_COUNT; i++)
        Cvar_Set(vr_overrides[i].name, vr_overrides[i].vrValue);
    // R13 — BOTH WHEELS ON THE GAZE. Upstream draws the weapon wheel a quarter-screen RIGHT of
    // centre and the powerup wheel a quarter-screen LEFT, which on a 40-degree head-locked quad
    // puts each of them ~10 degrees off-axis in opposite directions — so "point at the slot"
    // would mean two different reaches depending on which grip you pulled. Overlay 0015's anchor
    // already exists for the touch layer (centre the wheel on the button that opened it); VR
    // centres both on the quad, which is where the player is looking. Restored on exit with the
    // cvars, by the same crash-safe path.
    CL_iOS_SetWheelAnchor(0.5f, 0.5f);
    char line[192];
    Q_snprintf(line, sizeof(line), "VRSTASH stashed=%d applied=%d key=%s",
               (int)d.count, VR_OVERRIDE_COUNT, kStashKey.UTF8String);
    Q2_VR_BlackBoxPin("stash", line);
    Q2_VR_Log(line);
}

// Restore + write + clear, IN THAT ORDER, and the order is the whole mechanism (R2.1).
//
// WHAT WENT WRONG IN 1.0.11.2, because this is the kind of bug that comes back. The exit
// path wrote the config FIRST (the shell's synchronous writeconfig, which exists so a
// system dismissal that is really the first half of a swipe-kill still persists) and
// restored the cvars afterwards — so every ORDINARY VR exit wrote `gl_shadows 0`,
// `viewsize 100`, `gl_multisamples 0` into the player's own config and then quietly put
// the live cvars back. The stash worked perfectly on the crash path and was defeated on
// the path everybody actually takes. The lesson is not "call them in the other order at
// the call site": it is that the restore is not finished until the restored values are ON
// DISK, so the write belongs in here, where it cannot be ordered wrongly by a caller.
//
// And the clear comes LAST. The stash in NSUserDefaults is the only thing standing between
// a crash and a permanently clobbered config, so it is removed only once the repaired
// config has actually been written — never before.
//
//   VR_WRITE_NONE     caller is genuinely about to write (nothing uses this today; it is
//                     kept so the intent has a name if a caller ever earns it)
//   VR_WRITE_QUEUED   launch repair: Qcommon_Init is still coming up, so the write goes
//                     through the command buffer and runs on the first frame
//   VR_WRITE_INLINE   VR exit: main owns the frame again (the funnel is off by the time
//                     Q2_XR3_EngineExitVR gets here), so Cmd_ExecuteString runs inline and
//                     returns with the file on disk
enum { VR_WRITE_NONE = 0, VR_WRITE_QUEUED = 1, VR_WRITE_INLINE = 2 };

static void vr_restore_stash(int write, const char *why)
{
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:kStashKey];
    vr_stash_held = 0;
    if (!d.count) return;
    int n = 0;
    for (NSString *k in d) {
        id v = d[k];
        if (![v isKindOfClass:NSString.class]) continue;
        Cvar_Set(k.UTF8String, ((NSString *)v).UTF8String);
        n++;
    }
    // Write BEFORE clearing: if the process dies between these two statements the stash is
    // still in the defaults, and the launch repair puts it right.
    if (write == VR_WRITE_INLINE)
        Cmd_ExecuteString(&cmd_buffer, "writeconfig_boot");
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kStashKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    if (write == VR_WRITE_QUEUED)
        Cbuf_AddText(&cmd_buffer, "writeconfig_boot\n");
    char line[192];
    Q_snprintf(line, sizeof(line), "VRSTASH restored=%d why=%s wroteconfig=%d", n, why,
               write != VR_WRITE_NONE ? 1 : 0);
    Q2_VR_BlackBoxPin("stash", line);
    Q2_VR_Log(line);
}

// Called from Q2_XR3_EngineExitVR, which is the ONE finalize every VR exit goes through:
// the Exit-VR button, the Digital Crown / system dismissal (the layer's .invalidated
// branch reconciles the mode, which runs this same transition), a VR->3D switch, and the
// rollback of a failed entry. It writes the repaired config itself, so no call site can
// get the ordering wrong again.
void Q2_VR_RestoreCvars(void) { CL_iOS_SetWheelAnchor(-1.0f, -1.0f); vr_restore_stash(VR_WRITE_INLINE, "vrexit"); }

// Called once, after Qcommon_Init, from the same place the harness registers its commands.
// A stash that is still there at launch means the app did not get to run its exit path —
// which is precisely the case the mechanism exists for, so the repair is unconditional.
void Q2_VR_RepairLeftoverStash(void)
{
    NSDictionary *d = [NSUserDefaults.standardUserDefaults dictionaryForKey:kStashKey];
    if (!d.count) return;
    vr_restore_stash(VR_WRITE_QUEUED, "leftover_at_launch");
}

// =====================================================================================
// Dump fields — APPENDED to MOVENOW and BODYNOW, never inserted
// =====================================================================================

void Q2_VR_DumpMoveFields(char *out, int outsz)
{
    float lx, ly, rx, ry; int present, injected;
    pthread_mutex_lock(&pad_lock);
    pad_merged_locked(&lx, &ly, &rx, &ry, &present, &injected);
    pthread_mutex_unlock(&pad_lock);
    Q_snprintf(out, outsz,
               " pad=%d padinj=%d padL=(%.2f,%.2f) padR=(%.2f,%.2f) movedir=%s "
               "moveyaw=%.1fdeg moverotate=%d moveout=(%.1f,%.1f) turnmode=%s "
               "turnstep=%.0fdeg turnspeed=%.0fdeg_per_s turnarmed=%d turns=%d autopause=%d",
               present, injected, lx, ly, rx, ry, vr_movedir_name(),
               q2vr.move_yaw, q2vr.move_rotate, q2vr.move_out[0], q2vr.move_out[1],
               vr_snap ? "snap" : "smooth", vr_snap_step, vr_turn_speed,
               vr_turn_armed, vr_turns, Q2_iOS_AutoPauseHeld() ? 1 : 0);
}

void Q2_VR_DumpBodyFields(char *out, int outsz)
{
    // Snapshot the whole alignment set under one lock, then format: a dump that read the
    // yaw before a recentre and the counter after it would report a state that never
    // existed, which is worse than a stale one.
    float body_yaw, baseline, trim, eye;
    int recenters;
    pthread_mutex_lock(&align_lock);
    body_yaw  = vr_body_yaw;
    recenters = vr_recenters;
    baseline  = vr_height_baseline_m;
    trim      = vr_height_trim_m;
    eye       = vr_standing_eye_m_locked();
    pthread_mutex_unlock(&align_lock);

    // R3 — THE SEPARATION, in fields. `renderyaw` is what the frame was ACTUALLY rendered
    // with (written at the view.c site); `viewyaw` is what the client SENDS, which is allowed
    // to lag by a sim tick and is the server's business; `serveryaw` is the only engine-side
    // term the camera takes, and `yawsrc=pose` says the composition ran at all. The identity
    // an assertion can hold to is renderyaw == bodyyaw + headyaw + serveryaw, with no
    // client-simulated angle anywhere in it — which is the whole fix, stated as a number.
    Q_snprintf(out, outsz,
               " bodyyaw=%.1fdeg aimyaw=%.1fdeg aimpitch=%.1fdeg aimvalid=%d "
               "viewyaw=%.1fdeg recenters=%d baseline=%.3fm trim=%.3fm eye=%.3fm "
               "rise=%.1fu riseapplied=%.1fu ducked=%d ceilclamp=%d stash=%d "
               "renderyaw=%.1fdeg gameyaw=%.1fdeg serveryaw=%.1fdeg yawsrc=%s",
               body_yaw, q2vr.aim_angles[YAW], q2vr.aim_angles[PITCH], q2vr.aim_valid,
               q2vr.view_yaw_out, recenters,
               baseline, trim, eye,
               q2vr.rise, q2vr.rise_applied, q2vr.rise_ducked, q2vr.ceiling_clamp,
               vr_stash_held,
               vr_anglemod(q2vr.render_yaw), vr_anglemod(q2vr.game_yaw),
               vr_anglemod(q2vr.server_yaw),
               q2vr.yaw_from_pose ? "pose" : "none");
}

// =====================================================================================
// Console surface
// =====================================================================================

static void Cmd_VRPad_f(void)
{
    if (Cmd_Argc() < 5) {
        Q2_VR_ConPrintf("usage: q2vrpad <lx> <ly> <rx> <ry>   (the pad-poll OUTPUT boundary)\n");
        return;
    }
    float lx = Q_clipf((float)atof(Cmd_Argv(1)), -1.0f, 1.0f);
    float ly = Q_clipf((float)atof(Cmd_Argv(2)), -1.0f, 1.0f);
    float rx = Q_clipf((float)atof(Cmd_Argv(3)), -1.0f, 1.0f);
    float ry = Q_clipf((float)atof(Cmd_Argv(4)), -1.0f, 1.0f);
    Q2_VR_PadSticks(lx, ly, rx, ry, 1);
    // The left stick reaches the engine through the SAME bridge the real pad uses, so what a
    // simulator run exercises is the shipping move path and not a test-only shortcut.
    VID_iOS_AnalogMove(ly, lx);
    Q2_VR_ConPrintf("VRINJECT pad L=(%.2f,%.2f) R=(%.2f,%.2f)\n", lx, ly, rx, ry);
}

static void Cmd_VRRecenter_f(void)
{
    Q2_VR_RequestRecenter();
    Q2_VR_ConPrintf("q2vrrecenter: queued (the yaw-only base is re-captured on the next frame)\n");
}

static void Cmd_VRHeight_f(void)
{
    if (Cmd_Argc() < 2) {
        float baseline, trim, eye, rise;
        pthread_mutex_lock(&align_lock);
        baseline = vr_height_baseline_m; trim = vr_height_trim_m;
        eye = vr_standing_eye_m_locked(); rise = vr_rise_units_locked();
        pthread_mutex_unlock(&align_lock);
        Q2_VR_ConPrintf("q2vrheight baseline=%.3fm trim=%.3fm eye=%.3fm rise=%.1fu\n",
                   baseline, trim, eye, rise);
        Q2_VR_ConPrintf("usage: q2vrheight <trim metres -0.5..0.5> | q2vrheight recal\n");
        return;
    }
    if (!Q_stricmp(Cmd_Argv(1), "recal")) {
        // The re-capture arms the render thread's gate, so it is written under the lock the
        // render thread reads it through — this is the exact pairing R2.1 was about.
        pthread_mutex_lock(&align_lock);
        vr_height_baseline_m = 0.0f;
        vr_height_rejected = 0;
        pthread_mutex_unlock(&align_lock);
        Q2_VR_ConPrintf("q2vrheight: baseline cleared, re-capturing on the next tracked frame\n");
        return;
    }
    float trim = Q_clipf((float)atof(Cmd_Argv(1)), -0.5f, 0.5f), rise;
    pthread_mutex_lock(&align_lock);
    vr_height_trim_m = trim;
    rise = vr_rise_units_locked();
    pthread_mutex_unlock(&align_lock);
    Q2_VR_ConPrintf("VRSET heighttrim=%.3fm rise=%.1fu\n", trim, rise);
}

static void Cmd_VRTurn_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrturn mode=%s step=%.0fdeg speed=%.0fdeg_per_s\n",
                   vr_snap ? "snap" : "smooth", vr_snap_step, vr_turn_speed);
        Q2_VR_ConPrintf("usage: q2vrturn snap [step] | q2vrturn smooth [deg/s]\n");
        return;
    }
    if (!Q_stricmp(Cmd_Argv(1), "snap")) {
        vr_snap = 1;
        if (Cmd_Argc() > 2) vr_snap_step = Q_clipf((float)atof(Cmd_Argv(2)), 5.0f, 90.0f);
    } else if (!Q_stricmp(Cmd_Argv(1), "smooth")) {
        vr_snap = 0;
        if (Cmd_Argc() > 2) vr_turn_speed = Q_clipf((float)atof(Cmd_Argv(2)), 60.0f, 260.0f);
    } else {
        Q2_VR_ConPrintf("q2vrturn: mode must be snap or smooth\n");
        return;
    }
    vr_turn_armed = 1;
    Q2_VR_ConPrintf("VRSET turnmode=%s step=%.0fdeg speed=%.0fdeg_per_s\n",
               vr_snap ? "snap" : "smooth", vr_snap_step, vr_turn_speed);
}

static void Cmd_VRMoveDir_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrmovedir %s   (head | body | aimhand | offhand)\n", vr_movedir_name());
        return;
    }
    const char *s = Cmd_Argv(1);
    if (!Q_stricmp(s, "head"))         vr_movedir = 0;
    else if (!Q_stricmp(s, "body"))    vr_movedir = 1;
    else if (!Q_stricmp(s, "aimhand")) vr_movedir = 2;
    else if (!Q_stricmp(s, "offhand")) vr_movedir = 3;
    else { Q2_VR_ConPrintf("q2vrmovedir: head | body | aimhand | offhand\n"); return; }
    Q2_VR_ConPrintf("VRSET movedir=%s\n", vr_movedir_name());
}

// The head-locked UI quad's distance. 1.75 m is the donors' landing spot: near enough that
// the HUD reads at an eye's resolution, far enough that the eyes are not converging hard on
// it while also focusing on a world several metres away. Console-only, like the world scale.
static float vr_ui_dist_m = 1.75f;
float Q2_VR_UIDistance(void) { return vr_ui_dist_m; }

static void Cmd_VRUIDist_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vruidist %.2fm\n", vr_ui_dist_m); return; }
    vr_ui_dist_m = Q_clipf((float)atof(Cmd_Argv(1)), 0.5f, 6.0f);
    Q2_VR_ConPrintf("VRSET uidist=%.2fm\n", vr_ui_dist_m);
}

// R13 — DEPTH FOR A 2D WHEEL (Q-VR12). The wheel is a region of the ONE head-locked UI quad,
// so a per-element depth means a second composited surface and there is no cheap way to punch
// the wheel out of the first one. But `quadModel` derives the quad's half-width FROM its
// distance, so easing the whole quad closer while a wheel is open changes the vergence and the
// reprojection depth (uiParams = znear/dist) and leaves the angular size pixel-identical: real
// depth, zero draws, no new texture, no new pass. Eased over ~150 ms in the compositor, because
// a snapped vergence change is uncomfortable. 1.0 turns it off for a live A/B.
static float vr_wheel_pull = 0.65f;
float Q2_VR_WheelPull(void) { return vr_wheel_pull; }

static void Cmd_VRWheelPull_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrwheelpull %.2f\n", vr_wheel_pull); return; }
    vr_wheel_pull = Q_clipf((float)atof(Cmd_Argv(1)), 0.25f, 1.0f);
    Q2_VR_ConPrintf("VRSET wheelpull=%.2f\n", vr_wheel_pull);
}

// The redirect's fault injector, and the only honest way a simulator can prove the claim
// "the eye image carries ZERO 2D": shoot the eye with the redirect on, turn it off, shoot
// again, and require the two to DIFFER. A fixed expectation about HUD pixels would go stale;
// a difference measured twice in the same run cannot.
static void Cmd_VRUIRedirect_f(void)
{
    extern void VID_iOS_XR3_SetUIRedirect(int on);
    extern int  VID_iOS_XR3_UIReady(void);
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vruiredirect %d\n", VID_iOS_XR3_UIReady()); return; }
    VID_iOS_XR3_SetUIRedirect(atoi(Cmd_Argv(1)) != 0);
    Q2_VR_ConPrintf("VRSET uiredirect=%d\n", VID_iOS_XR3_UIReady());
}

// Q-VR9: the HUD's widescreen layout, live. A/B-able rather than a build flag, because the
// only honest way to judge "is the double r_config switch worth it" is to turn it off and on
// in the same session — and because it is the bail-out if the headset says otherwise.
// The eye-shape fault injector. A Vision Pro view is nearly square (~1920x1824); the
// simulator's drawable is 16:9. Without this, every "laid out for the wrong shape" assertion
// on a simulator is measuring a shape the device does not have.
//   q2vrphys 1920 1824   latch the headset's shape
//   q2vrphys 0 0         release it, back to whatever the compositor reports
static void Cmd_VRPhys_f(void)
{
    extern void Q2_VR_ForcePhysicalSize(int w, int h);
    extern void VID_iOS_XR3_EyeSize(int *w, int *h);
    if (Cmd_Argc() >= 3) Q2_VR_ForcePhysicalSize(atoi(Cmd_Argv(1)), atoi(Cmd_Argv(2)));
    int ew = 0, eh = 0;
    VID_iOS_XR3_EyeSize(&ew, &eh);
    Q2_VR_ConPrintf("VRSET physforce=%sx%s eye=%dx%d\n",
               Cmd_Argc() >= 3 ? Cmd_Argv(1) : "?", Cmd_Argc() >= 3 ? Cmd_Argv(2) : "?", ew, eh);
}

static void Cmd_VRHudWide_f(void)
{
    extern void VID_iOS_XR3_SetHudWide(int on);
    extern int  VID_iOS_XR3_HudWide(void);
    extern void VID_iOS_XR3_UIRect(int *w, int *h);
    if (Cmd_Argc() >= 2) VID_iOS_XR3_SetHudWide(atoi(Cmd_Argv(1)) != 0);
    int w = 0, h = 0;
    VID_iOS_XR3_UIRect(&w, &h);
    Q2_VR_ConPrintf("VRSET hudwide=%d hudrect=%dx%d\n", VID_iOS_XR3_HudWide(), w, h);
}

// R7b item 8 — the HUD's size and height, live. The rows store; this is the A/B, and it is
// what a simulator run drives (a settings sheet cannot be tapped from a script, and injecting
// NSUserDefaults writes would test the store rather than the draw path).
static void Cmd_VRHud_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrhud size=%.2f (mul %.2f mag %.2f) height=%+.2fm pos=%s spread=%.2f\n",
                   vr_hud_size, Q2_VR_HudSize(), Q2_VR_HudMagnify(), vr_hud_height,
                   vr_hud_pos == 0 ? "high" : vr_hud_pos == 1 ? "low" : "off", vr_hud_spread);
        Q2_VR_ConPrintf("usage: q2vrhud <size 0.85..3 row units; the ROW stops at 2.0, the "
                   "LAYOUT at 1.05 and the rest magnifies> "
                   "[height -0.6..0.6 m] [pos high|low|off] [spread 1..2]\n");
        return;
    }
    // Refused rather than read as zero, for the same reason q2vrgrip refuses one: a silent 0
    // here is a HUD that vanished, and the tuning session then chases a number nobody typed.
    char *end = NULL;
    double v = strtod(Cmd_Argv(1), &end);
    if (end == Cmd_Argv(1) || !isfinite(v)) {
        Q2_VR_ConPrintf("q2vrhud: '%s' is not a number\n", Cmd_Argv(1));
        return;
    }
    vr_hud_size = Q_clipf((float)v, VR_HUD_SIZE_MIN, VR_HUD_SIZE_DEVMAX);
    if (Cmd_Argc() >= 3) vr_hud_height = Q_clipf((float)atof(Cmd_Argv(2)), -0.6f, 0.6f);
    if (Cmd_Argc() >= 4) {
        const char *p = Cmd_Argv(3);
        if      (!Q_stricmp(p, "high")) vr_hud_pos = 0;
        else if (!Q_stricmp(p, "low"))  vr_hud_pos = 1;
        else if (!Q_stricmp(p, "off"))  vr_hud_pos = 2;
    }
    // R23 — the fourth argument, so Spread is A/B-able from the console the same way the
    // other three are. Clipped to the ROW's range and not to a dev maximum: unlike Size, this
    // one has no clipping cliff to go looking for, so there is nothing past 2.0 to measure.
    if (Cmd_Argc() >= 5)
        vr_hud_spread = Q_clipf((float)atof(Cmd_Argv(4)),
                                VR_HUD_SPREAD_MIN, VR_HUD_SPREAD_MAX);
    Q2_VR_ConPrintf("VRSET hudsize=%.2f hudmul=%.2f hudmag=%.2f hudheight=%+.2fm hudpos=%s "
               "hudspread=%.2f uiofs=%+.2fm\n",
               vr_hud_size, Q2_VR_HudSize(), Q2_VR_HudMagnify(), vr_hud_height,
               vr_hud_pos == 0 ? "high" : vr_hud_pos == 1 ? "low" : "off",
               vr_hud_spread, Q2_VR_UIHeightOffset());
}

static void Cmd_VRPitchTrim_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrpitchtrim %.1fdeg\n", vr_pitch_trim); return; }
    vr_pitch_trim = Q_clipf((float)atof(Cmd_Argv(1)), -15.0f, 15.0f);
    Q2_VR_ConPrintf("VRSET pitchtrim=%.1fdeg\n", vr_pitch_trim);
}

void Q2_VR_RegisterInputCommands(void)
{
    Cmd_AddCommand("q2vrpad",       Cmd_VRPad_f);
    Cmd_AddCommand("q2vrrecenter",  Cmd_VRRecenter_f);
    Cmd_AddCommand("q2vrheight",    Cmd_VRHeight_f);
    Cmd_AddCommand("q2vrturn",      Cmd_VRTurn_f);
    Cmd_AddCommand("q2vrmovedir",   Cmd_VRMoveDir_f);
    Cmd_AddCommand("q2vrpitchtrim", Cmd_VRPitchTrim_f);
    Cmd_AddCommand("q2vruidist",    Cmd_VRUIDist_f);
    Cmd_AddCommand("q2vrwheelpull", Cmd_VRWheelPull_f);
    Cmd_AddCommand("q2vruiredirect", Cmd_VRUIRedirect_f);
    Cmd_AddCommand("q2vrhudwide",   Cmd_VRHudWide_f);
    Cmd_AddCommand("q2vrhud",       Cmd_VRHud_f);
    Cmd_AddCommand("q2vrphys",      Cmd_VRPhys_f);
    // R4: the hands module's own surface (grip rig, fault injectors, haptic probe, doff).
    // Registered from here so there is one registration site for the whole VR input surface.
    Q2_VR_RegisterHandCommands();
}

#endif // Q2_XR_UI
