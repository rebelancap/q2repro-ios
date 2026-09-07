// q2_vr_hands.m — hands on the rendezvous, hand aim, the viewmodel mount and the aim dot.
//
// WHERE THE SEAM IS. `q2_vr_sense.m` answers "what did the hardware say"; this file answers
// "what does the game do with it". Everything above the boundary is Quake units, body yaw and
// usercmds; everything below it is GameController, ARKit and CoreHaptics. The synthetic
// injection commands write the struct BELOW the boundary, which is why a simulator run
// exercises this whole file rather than a parallel copy of it.
//
// THE ONE NAMED AIM FRAME. Three of the donors' most expensive bugs — inverted aim pitch,
// movement double-counting the head yaw, and an eye translation that made the camera orbit
// the recentre point — were one bug: a convention mismatch between two frames nobody wrote
// down. So the hand's angles come out of the SAME function the head's angles come out of
// (`q2_hand_angles`, the C twin of VRShell's `poseAngles`), against the SAME yaw-only base,
// in the SAME breath, riding the SAME frame id. There is one frame here, and it is named.
//
// THE SCALE SANDWICH, stated as arithmetic rather than as a matrix chain. The engine composes
// an eye as
//     vieworg + F*eyeofs[0] + R*eyeofs[1] + U*eyeofs[2]
// where F/R/U are the finished VR view basis. This file publishes the hand in the IDENTICAL
// form — head-local axes, world units, measured from the play-space origin — so the engine
// composes a hand with the eye's own two lines. Hands, eyes and weapon are in one frame by
// construction, not because two derivations were checked against each other.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include <string.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"
#include "system/system.h"
#include "client/keys.h"          // the KEX virtual pad keys the binds already own

#include "q2_vr_glue.h"
#include "q2_vr_sense.h"

extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a] Com_Printf, never the notify feed

extern void  Q2_VR_Log(const char *msg);
extern void  Q2_VR_BlackBoxPin(const char *key, const char *line);
extern float Q2_VR_WorldScale(void);
extern int   Q2_VR_Mode(void);
extern float Q2_VR_BodyYaw(void);
extern void  VID_iOS_AnalogMove(float forward, float side);
extern void  VID_iOS_KeyEvent(int keynum, bool down);
extern void  VID_iOS_MenuKey(int which, bool down);
extern void  VID_iOS_ToggleMenu(void);
extern bool  VID_iOS_MenuActive(void);
extern int   VID_iOS_PassiveState(void);   // 0 interactive, 1 demo, 2 cinematic
extern void  VID_iOS_SkipCinematic(void);
extern void  Q2_VR_PadStickSource(int source, float lx, float ly, float rx, float ry, int on);
enum { IOS_MENU_CLICK = 0, IOS_MENU_UP, IOS_MENU_DOWN, IOS_MENU_LEFT,
       IOS_MENU_RIGHT, IOS_MENU_ENTER, IOS_MENU_BACK };
enum { Q2VR_STICK_PAD = 0, Q2VR_STICK_HAND = 1 };

static float q2_anglemod(float a)
{
    a = fmodf(a, 360.0f);
    if (a > 180.0f) a -= 360.0f;
    if (a < -180.0f) a += 360.0f;
    return a;
}

// =====================================================================================
// The composition — compositor thread, in the head's breath
// =====================================================================================

// The C twin of VRShell's `poseAngles`, deliberately line-for-line: the head and the hands
// must be read out of a 4x4 by ONE piece of arithmetic. If this ever has to change, both
// copies change together or the port grows a second aim frame.
static void q2_hand_angles(simd_float4x4 m, float *yaw, float *pitch, float *roll)
{
    simd_float3 r = simd_make_float3(m.columns[0].x, m.columns[0].y, m.columns[0].z);
    simd_float3 u = simd_make_float3(m.columns[1].x, m.columns[1].y, m.columns[1].z);
    simd_float3 f = -simd_make_float3(m.columns[2].x, m.columns[2].y, m.columns[2].z);
    const float deg = 180.0f / (float)M_PI;
    float fy = f.y < -1.0f ? -1.0f : (f.y > 1.0f ? 1.0f : f.y);
    *yaw   = atan2f(-f.x, -f.z) * deg;
    *pitch = -asinf(fy) * deg;                          // Quake pitch is positive DOWN
    *roll  = -atan2f(r.y, u.y > 1e-4f ? u.y : 1e-4f) * deg;
}

// The last set the compositor composed, for the dumps and for the flat/UI contexts (which
// have no published pose to read). Written on the compositor thread, read on the engine
// thread and the main queue — a lock rather than atomics because it is a SET.
static pthread_mutex_t hand_lock = PTHREAD_MUTEX_INITIALIZER;
static q2_vr_hand_t    hand_last[2];
static uint64_t        hand_polls;

void Q2_VR_HandsCompose(simd_float4x4 base, int baseValid, q2_vr_hand_t out[2])
{
    q2_vr_sense_hand_t raw[2];
    const float ws = Q2_VR_WorldScale();

    Q2_VR_SensePoll(raw);
    memset(out, 0, 2 * sizeof(q2_vr_hand_t));

    for (int h = 0; h < 2; h++) {
        out[h].present = raw[h].present;
        out[h].buttons = raw[h].buttons;
        out[h].trigger = raw[h].trigger;
        out[h].grip    = raw[h].grip;
        out[h].stickX  = raw[h].stickX;
        out[h].stickY  = raw[h].stickY;
        if (!raw[h].posed || !baseValid) continue;      // present but not posed: honest

        // Into the SAME yaw-only base the head is expressed in. `base` is baseFromWorld, so
        // this is the hand in play space, and the numbers below are directly comparable with
        // the head's — which is the whole point of doing it here and not somewhere else.
        simd_float4x4 rel = simd_mul(base, raw[h].originFromHand);
        q2_hand_angles(rel, &out[h].yawDeg, &out[h].pitchDeg, &out[h].rollDeg);
        // The IDENTICAL convention as headFwd/headRight/headUp (metres, head-local axes,
        // measured from the play-space origin) — the engine multiplies both by the same
        // world scale and rotates both by the same basis.
        out[h].ofsFwd   = -rel.columns[3].z;
        out[h].ofsRight =  rel.columns[3].x;
        out[h].ofsUp    =  rel.columns[3].y;
        out[h].posed = 1;
        out[h].held  = raw[h].held;
    }
    (void)ws;

    pthread_mutex_lock(&hand_lock);
    hand_last[0] = out[0];
    hand_last[1] = out[1];
    hand_polls++;
    pthread_mutex_unlock(&hand_lock);
}

// =====================================================================================
// The settings rows this round consumes
// =====================================================================================
// Stored since R3 on purpose; the accessors live in q2_vr_input.m beside the rest of the
// settings application, and this file reads them rather than keeping a second copy.
extern int   Q2_VR_AimHandSetting(void);
extern int   Q2_VR_CrosshairSetting(void);
extern float Q2_VR_WeaponSizeSetting(void);   // the ENGINE multiplier (mapping applied)
extern float Q2_VR_WeaponSizeRow(void);       // the row value, for the dumps
extern int   Q2_VR_HapticsSetting(void);
extern float Q2_VR_PitchTrim(void);
extern int   Q2_VR_MoveDirMode(void);

int   Q2_VR_AimHand(void)     { return Q2_VR_AimHandSetting(); }
int   Q2_VR_CrosshairOn(void) { return Q2_VR_CrosshairSetting(); }
float Q2_VR_WeaponSize(void)  { return Q2_VR_WeaponSizeSetting(); }
int   Q2_VR_HapticsOn(void)   { return Q2_VR_HapticsSetting(); }

// =====================================================================================
// Grip calibration — LIVE, and as of R8 a SHIPPED CONSTANT again
// =====================================================================================
// R8. The six settings rows R7b added were a TUNING RIG with a deadline: they went
// into the headset on 1.0.11.10, were dialled, and the numbers read back. The numbers are
// below. The rig did its job, so the rows are gone — six sliders that nobody will ever move
// again are six ways to put the gun somewhere it cannot be recovered from, and the reason
// R7b gave for persisting them ("the tuning session IS the deliverable") expired with the
// session that produced them.
//
// `q2vrgrip` STAYS, dev-only and session-only, because it is how the next constant would be
// found if the mount ever changes. It no longer persists and no longer has a row behind it.
//
// Units are WORLD UNITS along the hand's own forward/right/up, and DEGREES about them.
// =====================================================================================
#define VR_GRIP_OFF_LIMIT  20.0f
#define VR_GRIP_ANG_LIMIT  30.0f
static float vr_grip[3]     = { -13.0f, -7.5f, 4.0f };  // forward, right, up (units) — R8, measured in the headset
static float vr_grip_ang[3] = {  0.0f,  0.0f, 0.0f };   // pitch, yaw, roll (degrees)

static void vr_grip_defaults(void)
{
    vr_grip[0] = -13.0f; vr_grip[1] = -7.5f; vr_grip[2] = 4.0f;
    vr_grip_ang[0] = vr_grip_ang[1] = vr_grip_ang[2] = 0.0f;
}

// The programmatic way in. ALL SIX OR NONE, and clamped here rather than at the caller,
// because `q2vrgrip` writes the same statics and a limit that lives in one of the two writers
// is a limit the other one can walk past. No settings row calls this any more (R8 deleted
// them); it stays because the console rig and any future caller must share one set of clamps.
void Q2_VR_SetGrip(float fwd, float right, float up, float pitch, float yaw, float roll)
{
    vr_grip[0] = Q_clipf(fwd,   -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
    vr_grip[1] = Q_clipf(right, -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
    vr_grip[2] = Q_clipf(up,    -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
    vr_grip_ang[0] = Q_clipf(pitch, -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
    vr_grip_ang[1] = Q_clipf(yaw,   -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
    vr_grip_ang[2] = Q_clipf(roll,  -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
}

// =====================================================================================
// Aim, movement, turning — the VR gameplay context
// =====================================================================================

static int   vr_hand_aim_on = 1;        // fault injector: q2vrhandaim 0 restores gamepad aim
static int   vr_pitch_comp  = 1;        // fault injector: q2vrpitchcomp 0 restores the bug
static int   vr_flick_on    = 1;        // right-stick flick weapon cycling
static int   vr_ctx_handoff = 1;        // fault injector: q2vrhandctx 0 reproduces bug #25
static int   vr_dot_on      = 1;
// R9 — THE SETTINGS ROW IS THE SOURCE OF TRUTH, not this. `q2vrdot <on> <scale>` remains,
// because the suite drives the reticle through it and a dev override is what lets a capture
// pin a size the store is not set to — but it is now an OVERRIDE and 0 means "no override,
// follow Crosshair Size". Anything else would give the harness and the player two different
// reticles and only one of them would ever be looked at.
static float vr_dot_scale   = 0.0f;     // 0 = follow the Crosshair Size row
static float Q2_VR_DotScale(void)
{
    return vr_dot_scale > 0.01f ? vr_dot_scale : Q2_VR_CrosshairSize();
}

// Arbitration. The aim hand owns aim while it is posed; a LOSS costs two frames of hysteresis
// (a dropped anchor is usually momentary, and snapping to the head for a single frame reads
// as a flick), while an ACQUIRE is immediate. The gamepad is not disturbed either way: with
// no hand posed this whole file is inert and R2/R3's behaviour is what runs.
#define VR_HAND_MISS_MAX 3
static int   vr_hand_miss = VR_HAND_MISS_MAX;
static int   vr_aim_from_hand;          // identity, not intent: what the last frame used
static float vr_aim_yaw, vr_aim_pitch;  // the aim source's own angles, degrees
static int   vr_turns_flick;

// The engine-thread view of the published hands, refreshed once per host frame.
static q2_vr_hand_t vr_hand_cur[2];

// WHO OWNS THE PAIR THIS INSTANT, and why this is atomic and doubled.
//
// The world consumer runs on the engine thread and the UI pump runs on the main queue, and
// BOTH drain the one edge detector. If they can ever run in the same window, a press lands in
// whichever happened to drain first — and, worse, each one's context note sees the other's and
// rebases, so the pending edges are wiped before anybody acts on them. That is exactly what a
// first sim run showed: a button visibly HELD in the level dump (`btnL=0x04`) with `heldkeys=0`
// and the context oscillating, i.e. two consumers and no owner.
//
// So the interlock is atomic, and the pump ALSO asks the arbitration itself rather than
// trusting a flag another thread toggles: in VR, a world frame belongs to the engine thread by
// definition, and `Q2_VR_PresentIsWorld` is the same predicate the engine frame branches on.
// One question, one answer, both sides.
static atomic_int   vr_world_ctx;
int Q2_VR_HandsDrivesWorld(void) { return atomic_load(&vr_world_ctx); }

// Which physical hand is which ROLE. Buttons are routed by role, not by side, so a
// left-handed player's aim hand carries +attack exactly as a right-handed player's does.
static int vr_aim_index(void) { return Q2_VR_AimHand() ? 1 : 0; }
static int vr_off_index(void) { return Q2_VR_AimHand() ? 0 : 1; }

// ---- button routing ------------------------------------------------------------------
// THE SENSE PAIR IS ONE LOGICAL GAMEPAD (R7b item 7). Second headset verdict: "the vr
// controllers should replicate what they are for a gamepad … all the same buttons are present."
//
// The program rule that makes that cheap: the shell never hardcodes a controller ACTION. Every
// Sense button emits one distinct virtual key that the engine's own bind table owns, and the
// keys chosen are the ones the rerelease default.cfg already binds for a gamepad — so the
// weapon wheel, +attack and everything else work unmodified and stay rebindable. The pair is
// then a gamepad by construction rather than by a translation table somebody has to maintain.
//
// THE MAP, aim hand = right by default (Aim Hand swaps the ROLES, not the sides, so a
// left-handed player's aim hand carries the right-hand column):
//
//   Sense element        aim hand          off hand          gamepad
//   -------------------  ----------------  ----------------  ---------------------------
//   Trigger              K_RIGHT_TRIGGER   K_LEFT_TRIGGER    RT / LT   (+attack / +moveup)
//   Grip                 K_RIGHT_SHOULDER  K_LEFT_SHOULDER   RB / LB   (+wheel / +wheel2)
//   Face, bottom (A)     K_A_BUTTON        K_X_BUTTON        A  / X    (+moveup / cmd help)
//   Face, top    (B)     K_B_BUTTON        -- see below --   B  / Y
//   Stick click          K_RIGHT_STICK     K_LEFT_STICK      R3 / L3
//   Stick                turn / flick      move              R-stick / L-stick
//   Menu (☰) either hand      Start                          ☰  (menu + pause)
//
// TWO DELIBERATE DEPARTURES, both because the pair is not shaped like a pad:
//
//   * THE OFF HAND'S TOP FACE BUTTON IS START, not K_Y_BUTTON. It was K_Y_BUTTON, which the
//     rerelease default.cfg does not bind at all, and in menus BOTH top face buttons were Back
//     — the reported "wasted duplicate". Meanwhile the other complaint was that no face button
//     opens the menu. A Sense pair carries at most one hardware ☰ and some report none, so the
//     one element the gamepad layout leaves dead becomes the one element the pair is missing.
//     It emits Start and NOT K_Y_BUTTON: one physical press is one logical event (the D5
//     partition rule), never both.
//   * THERE IS NO D-PAD, because there is no fourth digital cluster on a Sense pair to put one
//     on. The two D-pad actions the rerelease layout binds — cl_weapprev and cl_weapnext — are
//     already carried, by the aim-hand stick flick, which is a VR-reserved input and takes
//     precedence in world frames. Synthesising a D-pad from a stick that is simultaneously the
//     turn axis would be the double-emission the partition rule forbids.
//
// `offKey == 0` means the off hand does not emit a bind key for that element; the routing loop
// skips it and the element is handled by name below.
static const struct { unsigned bit; int aimKey; int offKey; } vr_btn_keys[] = {
    { Q2_SENSE_TRIGGER, K_RIGHT_TRIGGER,  K_LEFT_TRIGGER  },
    { Q2_SENSE_GRIP,    K_RIGHT_SHOULDER, K_LEFT_SHOULDER },
    { Q2_SENSE_A,       K_A_BUTTON,       K_X_BUTTON      },
    { Q2_SENSE_B,       K_B_BUTTON,       0               },   // off hand's B is Start
    { Q2_SENSE_STICK,   K_RIGHT_STICK,    K_LEFT_STICK    },
};
#define VR_BTN_KEY_COUNT ((int)(sizeof(vr_btn_keys) / sizeof(vr_btn_keys[0])))

// Every element that acts as the gamepad's ☰, in one expression, so the world frame and the UI
// pump cannot disagree about which presses are Start. The off hand's top face button is here
// and NOT in the bind loop above — that is the no-double-emission half of the same decision.
static unsigned vr_start_mask(unsigned aimDown, unsigned offDown)
{
    return ((aimDown | offDown) & Q2_SENSE_MENU) | (offDown & Q2_SENSE_B);
}

// ONE Start press, wherever it came from. Skips a cinematic if one is playing (R7b item 6),
// otherwise opens or closes the menu — and the menu-open PAUSES a live single-player game,
// which is the half of "OPTIONS should be the pause menu" that was missing. The whole body
// lives in the shell bridge so the gamepad's own ☰ runs the identical code; a second copy here
// is how the two would drift.
extern void VID_iOS_PadStartButton(void);
extern int  Q2_VR_UIStartCount;

static void vr_start_press(void)
{
    Q2_VR_UIStartCount++;
    VID_iOS_PadStartButton();
}

// What THIS module currently holds down, so a release can be issued exactly once and only
// for keys it pressed. `+attack` is shared with the gamepad, the touch layer and every bind,
// so an unconditional per-frame release would silently cancel a gamepad player's trigger.
static unsigned vr_held_keys;       // bitmask over vr_btn_keys x {aim, off}
static int      vr_held_count;

// The shared analog-move latch. Writes while the stick is deflected, writes ONE zero when it
// returns to centre, and is silent otherwise — so two producers on two threads can share the
// bridge without either cancelling the other.
static int vr_moving;
static void vr_move_latch(float x, float y)
{
    if (fabsf(x) > 0.15f || fabsf(y) > 0.15f) {
        VID_iOS_AnalogMove(y, x);
        vr_moving = 1;
    } else if (vr_moving) {
        VID_iOS_AnalogMove(0, 0);
        vr_moving = 0;
    }
}

static void vr_press(int slot, int key, bool down)
{
    unsigned bit = 1u << slot;
    if (down) {
        if (vr_held_keys & bit) return;
        vr_held_keys |= bit;
        vr_held_count++;
        VID_iOS_KeyEvent(key, true);
    } else {
        if (!(vr_held_keys & bit)) return;
        vr_held_keys &= ~bit;
        if (vr_held_count > 0) vr_held_count--;
        VID_iOS_KeyEvent(key, false);
    }
}

// Release everything WE hold, once. Called when the hands stop answering (doff, disconnect,
// tracking loss with no controller left), and on a context handoff.
static void vr_release_held(const char *why)
{
    if (!vr_held_keys) return;
    for (int i = 0; i < VR_BTN_KEY_COUNT; i++) {
        if (vr_held_keys & (1u << (i * 2 + 0))) vr_press(i * 2 + 0, vr_btn_keys[i].aimKey, false);
        if (vr_btn_keys[i].offKey &&
            (vr_held_keys & (1u << (i * 2 + 1)))) vr_press(i * 2 + 1, vr_btn_keys[i].offKey, false);
    }
    if (vr_moving) { VID_iOS_AnalogMove(0, 0); vr_moving = 0; }
    Q2_VR_PadStickSource(Q2VR_STICK_HAND, 0, 0, 0, 0, 0);
    char line[128];
    Q_snprintf(line, sizeof(line), "VRHANDS released everything held (%s)", why ? why : "-");
    Q2_VR_Log(line);
}

// Context handoff. Forget the pending edges, keep the held LEVEL, release what we hold: no
// latch crosses a boundary and no release fires blind. `q2vrhandctx 0` restores the donors'
// bug on demand, which is what turns "we fixed it" into a provable claim.
static int vr_last_ctx = -1;
static void vr_note_context(int ctx)
{
    if (ctx == vr_last_ctx) return;
    vr_last_ctx = ctx;
    if (!vr_ctx_handoff) return;
    vr_release_held("context handoff");
    Q2_VR_SenseRebaseEdges();
}

// ---- the weapon flick ------------------------------------------------------------------
// The SAME hysteresis shape as the snap turn (fire above 0.6, re-arm below 0.4) on the SAME
// stick, separated by AXIS: X turns, Y cycles. Two extra terms stop a diagonal
// turn-and-glance from switching weapons — the cross-axis magnitude has to be small AND the
// vertical has to dominate it — which is the measured fix a donor needed after shipping the
// two-condition version.
// ---- the wheel cursor (R13) ------------------------------------------------------------
// REAL DEVICE REPORT: "The weapon and inventory wheels don't work. I should be able to use my
// VR cursor to select which one I want and let go to select it."
//
// He was right about the shape of it: the wheel is a 2D CURSOR, not a stick axis. Upstream
// accumulates cl.wheel.position, picks the slot whose unit direction the cursor points at, and
// confirms on the RELEASE — so once a cursor exists, letting go already works. In a VR world
// frame there was no cursor: the Sense sticks go to the snap-turn snapshot and CL_AdjustAngles,
// which carries all three existing producers, is never reached.
//
// THE MAPPING IS A RAY/PLANE INTERSECTION, not a small-angle approximation, because the quad is
// not where the naive version assumes. `quadModel` (VRShell.swift) places the HUD quad at
// Q2_VR_UIDistance() metres along the head's YAW-ONLY forward, offset vertically by
// Q2_VR_UIHeightOffset(), and TILTS it to face the head — with the default Low anchor that is
// 0.66 m below the head at 1.75 m, i.e. a centre ~21 degrees down and a plane that is not
// perpendicular to anything. Two consequences a difference-of-angles version gets wrong:
//
//   * the quad's vertical placement does NOT follow head PITCH (fwd.y is zeroed), so the ray's
//     pitch here is the hand's ABSOLUTE pitch and the head's pitch does not appear at all. Only
//     the YAW is differenced.
//   * the plane's tilt couples u and v, which a pair of independent angle ratios cannot express.
//
// Both are free once the intersection is written out, and being exact here is what lets the
// player point AT the slot they can see rather than at a slot the arithmetic thinks is there.
// The ray is treated as leaving the HEAD, not the hand: the hand's own translation would move
// the cursor without the player rotating anything, which reads as drift.
extern int  CL_iOS_WheelOpen(void);            // overlay 0038: 0 closed, 1 weapon, 2 powerup
extern int  CL_iOS_WheelSelected(void);
extern int  CL_iOS_VRWheelCursorNDC(float u, float v);

static int   vr_wheel_sel_last = -2;
static float vr_wheel_u, vr_wheel_v;           // the last cursor, for WHEELNOW and the dumps

// R14 — WHICH HAND DRIVES THE CURSOR. Headset report: "change the inventory wheel to use the
// LEFT controller to select your item instead of the right. That way each controller matches:
// grip and movement to open the wheel and select."
//
// The rule, stated once so it cannot drift: THE HAND WHOSE GRIP OPENED THE WHEEL DRIVES IT.
// The aim hand's grip is +wheel (the weapon wheel) and the off hand's is +wheel2 (the powerup /
// inventory wheel) — see the bind map above — so the cursor hand simply follows the wheel that
// is open. That is automatically right for a left-handed player too: Aim Hand swaps the ROLES,
// so it swaps which physical grip opens which wheel and this expression swaps with it. One
// controller is never asked to hold a grip while the other one aims.
static int vr_wheel_hand(int open)
{
    return open == 2 ? vr_off_index() : vr_aim_index();
}

static void vr_wheel_step(float headYaw)
{
    const int open = CL_iOS_WheelOpen();
    if (!open) { vr_wheel_sel_last = -2; return; }

    const int ai = vr_wheel_hand(open);
    if (!vr_hand_cur[ai].posed) return;

    // The quad, from the SAME accessors the compositor places it with. Reading them here rather
    // than caching a copy is the rule this file already follows for every other row: a setting
    // the player is dragging must move the cursor under their hand, and a second copy of the
    // placement is how the cursor and the quad end up in different places.
    const float d = Q2_VR_UIDistance();
    const float h = Q2_VR_UIHeightOffset();
    int urw = 0, urh = 0;
    VID_iOS_XR3_UIRect(&urw, &urh);
    const float aspect = (urw > 0 && urh > 0) ? (float)urw / (float)urh : 1.0f;
    const float es     = fmaxf(1.0f, Q2_VR_HudMagnify());
    const float halfW  = d * tanf((float)M_PI / 9.0f) * es;      // tan(20 deg): 40 deg across
    const float halfH  = halfW / (aspect > 0.2f ? aspect : 0.2f);
    const float L      = sqrtf(d * d + h * h);
    if (halfW <= 0.0f || halfH <= 0.0f || L <= 0.0f) return;

    // The ray, in the head's yaw-only basis: x right, y up, z BACKWARD (the basis quadModel
    // builds). Quake pitch is positive DOWN, which is the minus on Dy.
    const float rad  = (float)M_PI / 180.0f;
    const float dyaw = q2_anglemod(vr_hand_cur[ai].yawDeg - headYaw) * rad;
    const float pit  = vr_hand_cur[ai].pitchDeg * rad;
    const float cp = cosf(pit), sp = sinf(pit);
    const float Dx = -cp * sinf(dyaw);        // +yaw is LEFT, +x is right
    const float Dy = -sp;
    const float Dz = -cp * cosf(dyaw);

    // The plane through the quad's centre C = (0, h, -d) with normal N = (0, -h, d)/L (it faces
    // the head). C.N is -L exactly, so the intersection is t = -L / (D.N).
    const float DN = (-Dy * h + Dz * d) / L;
    if (DN > -1e-4f) return;                  // pointing away from the quad: leave the cursor be
    const float t  = -L / DN;

    float u =  (t * Dx) / halfW;                          // the quad's right axis
    float v = -(t * (Dy * d + Dz * h) / L) / halfH;       // its up axis; screen v is DOWN
    u = Q_clipf(u, -4.0f, 4.0f);                          // the engine clamps to the ring anyway
    v = Q_clipf(v, -4.0f, 4.0f);
    vr_wheel_u = u; vr_wheel_v = v;

    CL_iOS_VRWheelCursorNDC(u, v);

    // A ring you can feel is a ring you can use without staring at it.
    const int sel = CL_iOS_WheelSelected();
    if (sel != vr_wheel_sel_last) {
        if (sel >= 0 && vr_wheel_sel_last != -2) Q2_VR_Haptic(ai, 0.25f, 0.015f, "wheelslot");
        vr_wheel_sel_last = sel;
    }
}

// The quad the ray was intersected with, reported alongside the cursor it produced. A suite
// case has to be able to AIM at a named slot, and aiming means inverting this mapping — so the
// four numbers it needs come out of the shipping code rather than out of a second copy of the
// constants in a shell script, which is how a test starts passing against arithmetic that has
// moved. `vrhub` is the pitch that puts the cursor on the wheel's hub with the head level.
void Q2_VR_DumpWheelFields(char *out, int outsz)
{
    // R14: the hand REPORTED is the hand that would drive the cursor right now — the wheel's
    // own hand while one is open, the aim hand when none is. A dump that always said "aim"
    // could not tell a suite whether the powerup wheel was following the correct controller.
    const int ai = vr_wheel_hand(CL_iOS_WheelOpen());
    int urw = 0, urh = 0;
    VID_iOS_XR3_UIRect(&urw, &urh);
    const float d = Q2_VR_UIDistance(), h = Q2_VR_UIHeightOffset();
    Q_snprintf(out, outsz,
               " vru=%.3f vrv=%.3f vrsel=%d vrhand=%s vrposed=%d vrhandyaw=%.2f "
               "vrhandpitch=%.2f vrd=%.4f vrh=%.4f vrasp=%.4f vres=%.4f vrhub=%.3f",
               vr_wheel_u, vr_wheel_v, vr_wheel_sel_last, ai ? "r" : "l",
               vr_hand_cur[ai].posed, vr_hand_cur[ai].yawDeg, vr_hand_cur[ai].pitchDeg,
               d, h, (urw > 0 && urh > 0) ? (float)urw / (float)urh : 1.0f,
               fmaxf(1.0f, Q2_VR_HudMagnify()),
               atan2f(-h, d) * 180.0f / (float)M_PI);
}

#define VR_FLICK_Y_ON   0.60f
#define VR_FLICK_Y_OFF  0.40f
#define VR_FLICK_X_MAX  0.25f
#define VR_FLICK_RATIO  2.5f
static int vr_flick_armed = 1;

static void vr_flick_step(float x, float y)
{
    if (!vr_flick_on) return;
    // R13: the flick and the wheel are the same intent expressed twice. Grip held + stick up ran
    // `weapnext`, which opens the CAROUSEL on top of the wheel the grip just opened. Disarmed
    // rather than merely skipped, so the stick has to return to centre before the next flick —
    // otherwise letting go of the grip while still pushing up fires one immediately.
    if (CL_iOS_WheelOpen()) { vr_flick_armed = 0; return; }
    if (fabsf(y) < VR_FLICK_Y_OFF) vr_flick_armed = 1;
    if (!vr_flick_armed) return;
    if (fabsf(y) < VR_FLICK_Y_ON) return;
    if (fabsf(x) > VR_FLICK_X_MAX) return;
    if (fabsf(y) < VR_FLICK_RATIO * fabsf(x)) return;
    vr_flick_armed = 0;
    vr_turns_flick++;
    Cbuf_AddText(&cmd_buffer, y > 0 ? "weapnext\n" : "weapprev\n");
    Q2_VR_Haptic(vr_aim_index(), 0.3f, 0.02f, "weapflick");
}

// =====================================================================================
// The per-frame consumer — VR gameplay (engine thread, before Qcommon_Frame)
// =====================================================================================
// Returns 1 when the hands own the aim this frame; q2_vr_input.m then leaves the head aim
// alone. Everything the gamepad path does is untouched when this returns 0, which is the
// no-regression contract for R2/R3.
int Q2_VR_HandsWorldFrame(const void *posePtr, float headYaw, float headPitch)
{
    const q2_vr_pose_t *pose = (const q2_vr_pose_t *)posePtr;
    unsigned down[2] = {0, 0}, up[2] = {0, 0}, level[2] = {0, 0};
    float stick[4] = {0, 0, 0, 0};
    int hands;

    atomic_store(&vr_world_ctx, 1);
    vr_note_context(1);

    if (pose) {
        vr_hand_cur[0] = pose->hand[0];
        vr_hand_cur[1] = pose->hand[1];
    }
    hands = Q2_VR_SenseTakeEdges(down, up, level, stick);

    // RELEASE-ON-DOFF. No hands answering means the pair is gone (both disconnected, the
    // headset came off, or tracking died with nothing left) — release once and stop.
    if (hands <= 0) {
        vr_release_held("no hands");
        vr_hand_miss = VR_HAND_MISS_MAX;
        vr_aim_from_hand = 0;
        memset(vr_hand_cur, 0, sizeof(vr_hand_cur));
        return 0;
    }

    const int ai = vr_aim_index(), oi = vr_off_index();

    // ---- aim arbitration -----------------------------------------------------------
    if (vr_hand_aim_on && vr_hand_cur[ai].posed) vr_hand_miss = 0;
    else if (vr_hand_miss < VR_HAND_MISS_MAX)    vr_hand_miss++;
    vr_aim_from_hand = (vr_hand_aim_on && vr_hand_miss < VR_HAND_MISS_MAX);

    // ---- buttons -------------------------------------------------------------------
    for (int i = 0; i < VR_BTN_KEY_COUNT; i++) {
        if (down[ai] & vr_btn_keys[i].bit) vr_press(i * 2 + 0, vr_btn_keys[i].aimKey, true);
        if (up[ai]   & vr_btn_keys[i].bit) vr_press(i * 2 + 0, vr_btn_keys[i].aimKey, false);
        if (!vr_btn_keys[i].offKey) continue;
        if (down[oi] & vr_btn_keys[i].bit) vr_press(i * 2 + 1, vr_btn_keys[i].offKey, true);
        if (up[oi]   & vr_btn_keys[i].bit) vr_press(i * 2 + 1, vr_btn_keys[i].offKey, false);
    }
    if (vr_start_mask(down[ai], down[oi])) vr_start_press();
    // The one piece of feel this file owns rather than binds: firing should be felt in the
    // hand that fired. Short, so it is a transient and not a hum.
    if (down[ai] & Q2_SENSE_TRIGGER) Q2_VR_Haptic(ai, 0.7f, 0.03f, "attack");

    // ---- sticks, into the ONE merged snapshot --------------------------------------
    // The off hand moves and the aim hand turns — the donors' layout, and the one that keeps
    // "point where you shoot" and "turn with your thumb" on different limbs. The values go
    // into the SAME snapshot the gamepad writes, so the snap-turn hysteresis, the smooth-turn
    // integration and the movement rotation are the code R2 already shipped and not a second
    // copy of it beside them.
    const float mx = (oi == 0) ? stick[0] : stick[2];
    const float my = (oi == 0) ? stick[1] : stick[3];
    const float tx = (ai == 0) ? stick[0] : stick[2];
    const float ty = (ai == 0) ? stick[1] : stick[3];
    Q2_VR_PadStickSource(Q2VR_STICK_HAND, mx, my, tx, ty, 1);
    // ZERO ONLY ON THE FALLING EDGE, never every frame. `VID_iOS_AnalogMove` is a shared
    // latch: the gamepad driver writes it from the main queue and this writes it from the
    // engine thread, so an unconditional zero here would cancel a gamepad player's stick on
    // every frame their hands happened to be still — a regression that would read as a broken
    // controller. The gamepad driver keeps the same latch for the same reason.
    vr_move_latch(mx, my);
    // The wheel BEFORE the flick, because the flick asks whether a wheel is open, and after the
    // button loop, because the grip that opens the wheel is pressed in it — so the frame that
    // opens the wheel is also the frame that first places its cursor.
    vr_wheel_step(headYaw);
    vr_flick_step(tx, ty);

    // ---- the aim source ------------------------------------------------------------
    if (vr_aim_from_hand) {
        vr_aim_yaw   = vr_hand_cur[ai].yawDeg;
        vr_aim_pitch = vr_hand_cur[ai].pitchDeg + Q2_VR_PitchTrim();
    } else {
        vr_aim_yaw   = headYaw;
        vr_aim_pitch = headPitch + Q2_VR_PitchTrim();
    }
    return vr_aim_from_hand;
}

// What q2_vr_input.m needs to finish the frame. Kept as small accessors rather than a shared
// struct: each one is read at exactly one site, and a struct would invite a second reader
// that samples half of it.
int   Q2_VR_HandsAimActive(void) { return vr_aim_from_hand; }
float Q2_VR_HandsAimYaw(void)    { return vr_aim_yaw; }
float Q2_VR_HandsAimPitch(void)  { return vr_aim_pitch; }

// The movement basis, as a rotation of the FINISHED wish vector (charter D5). `sentRel` is
// the yaw the client is about to send, minus the body — i.e. whichever source won the aim
// arbitration. The desired movement yaw is the mode's own source. Head mode was a zero
// rotation for the whole of R2/R3 because the head WAS the aim source; with a hand aiming it
// stops being zero, which is exactly what makes the row real.
float Q2_VR_HandsMoveYaw(float headYaw, float sentRelYaw, int *rotate)
{
    const int mode = Q2_VR_MoveDirMode();       // 0 head, 1 body, 2 aim hand, 3 off hand
    float desired = sentRelYaw;
    switch (mode) {
    case 0: desired = headYaw; break;
    case 1: desired = 0.0f; break;              // the body itself: console-only mode
    case 2: desired = vr_hand_cur[vr_aim_index()].posed
                    ? vr_hand_cur[vr_aim_index()].yawDeg : headYaw; break;
    case 3: desired = vr_hand_cur[vr_off_index()].posed
                    ? vr_hand_cur[vr_off_index()].yawDeg : headYaw; break;
    default: break;
    }
    float dy = q2_anglemod(desired - sentRelYaw);
    if (rotate) *rotate = (fabsf(dy) > 0.01f);
    return dy;
}

// The viewmodel and the aim dot, written into the engine's VR gate once per host frame.
// Offsets are the aim hand's, in the eye's own form; angles carry the grip rotation while the
// AIM RAY does not — the grip correction moves the MODEL only, or the gun and the shot would
// disagree by exactly the calibration.
void Q2_VR_HandsPublishViewmodel(void)
{
    const int ai = vr_aim_index();
    const float ws = Q2_VR_WorldScale();
    q2vr.weapon_scale = Q2_VR_WeaponSize();
    // R13 — "users who turn OFF their cursor need the cursor to appear when they activate their
    // weapon wheels." While a wheel is open the aim dot IS the cursor, so the user SETTING is
    // overridden for exactly as long as one is open. `q2vrdot` — the dev kill switch, which is
    // what a device round turns off to prove the dot is what it is looking at — still wins.
    // R14 — only the WEAPON wheel forces it. The powerup wheel is steered by the OFF hand
    // (vr_wheel_hand), while the dot rides the AIM hand's ray, so forcing it there would put a
    // cursor at the hand the player is not pointing with — the engine-drawn puck is the cursor
    // for that wheel. The player's own VR Crosshair setting stands while it is open.
    const int wheel_forces_dot = CL_iOS_WheelOpen() == 1;
    q2vr.aim_dot = (vr_dot_on && (Q2_VR_CrosshairOn() || wheel_forces_dot)) ? 1 : 0;
    q2vr.aim_dot_scale = Q2_VR_DotScale();
    q2vr.pitch_comp = vr_pitch_comp;
    q2vr.suppress_kick = 1;
    for (int i = 0; i < 3; i++) q2vr.grip_ofs[i] = vr_grip[i];

    if (!vr_aim_from_hand || !vr_hand_cur[ai].posed) {
        q2vr.hand_valid = 0;
        return;
    }
    q2vr.hand_valid = 1;
    q2vr.hand_ofs[0] = vr_hand_cur[ai].ofsFwd   * ws;
    q2vr.hand_ofs[1] = vr_hand_cur[ai].ofsRight * ws;
    q2vr.hand_ofs[2] = vr_hand_cur[ai].ofsUp    * ws;
    // Yaw carries the BODY yaw here, exactly as the head's published yaw does, so the engine
    // adds only the server's own re-orientation to either of them and the hand and the camera
    // are re-oriented by a teleport in one step. Publishing a body-relative hand yaw and
    // asking the engine to find the body would be a second place that has to re-derive it.
    const float body = Q2_VR_BodyYaw();
    q2vr.hand_ang[PITCH] = vr_hand_cur[ai].pitchDeg + vr_grip_ang[0];
    q2vr.hand_ang[YAW]   = q2_anglemod(body + vr_hand_cur[ai].yawDeg) + vr_grip_ang[1];
    q2vr.hand_ang[ROLL]  = vr_hand_cur[ai].rollDeg  + vr_grip_ang[2];
    // The RAY, ungripped: the grip correction moves the MODEL only. If the ray took it too,
    // the gun and the shot would disagree by exactly the calibration, and the aim dot would
    // confirm the wrong one.
    q2vr.hand_ray_ang[PITCH] = vr_hand_cur[ai].pitchDeg;
    q2vr.hand_ray_ang[YAW]   = q2_anglemod(body + vr_hand_cur[ai].yawDeg);
    q2vr.hand_ray_ang[ROLL]  = 0.0f;
}

// Leaving VR gameplay: drop the gate so the engine takes its ordinary paths, and release
// anything held. Called from the non-world branch of the input frame.
void Q2_VR_HandsWorldIdle(void)
{
    atomic_store(&vr_world_ctx, 0);
    q2vr.hand_valid = 0;
    q2vr.aim_dot = 0;
    vr_aim_from_hand = 0;
    vr_hand_miss = VR_HAND_MISS_MAX;
}

// =====================================================================================
// The UI pump and the flat merge — charter D5 contexts 2 and 3
// =====================================================================================
// Runs from the SAME place the gamepad is polled (`pollController`, main queue), because that
// is the home input already has in every mode: the 2D window's display link, the 3D panel's
// display link, and the 90 Hz pad timer that replaces the link under `.full` immersion. The
// pump does not need a compositor frame, an alignment or a pose — a menu does not care where
// your hand is.
static double vr_ui_repeat_at;
static int    vr_ui_repeat_key = -1;
int           Q2_VR_UIEnterCount, Q2_VR_UIEscCount, Q2_VR_UISkipCount, Q2_VR_UIStartCount;

static void vr_menu_axis(float v, int keyPos, int keyNeg, double now)
{
    int want = (v > 0.5f) ? keyPos : (v < -0.5f ? keyNeg : -1);
    if (want < 0) { vr_ui_repeat_key = -1; return; }
    if (want != vr_ui_repeat_key) {
        vr_ui_repeat_key = want;
        vr_ui_repeat_at = now + 0.4;            // first step, then autorepeat
        VID_iOS_MenuKey(want, true);
        VID_iOS_MenuKey(want, false);
        return;
    }
    if (now >= vr_ui_repeat_at) {
        vr_ui_repeat_at = now + 0.15;
        VID_iOS_MenuKey(want, true);
        VID_iOS_MenuKey(want, false);
    }
}

void Q2_VR_HandsUIFrame(void)
{
    unsigned down[2] = {0, 0}, up[2] = {0, 0}, level[2] = {0, 0};
    float stick[4] = {0, 0, 0, 0};
    unsigned btn[2];
    float ui[4];
    int hands;

    // In a VR world frame the engine thread owns the pair; draining here would steal its edges
    // and the same press would land in two contexts. Asked TWO ways on purpose — the flag the
    // engine sets, and the arbitration predicate the engine branches on — because the flag
    // alone is a cross-thread read that can be momentarily stale, and a momentarily-stale
    // answer here costs a press.
    if (atomic_load(&vr_world_ctx)) return;
    if (Q2_VR_Mode() == 2 && Q2_VR_PresentIsWorld()) return;

    // Sample without ARKit, which also folds the level into the one detector — the only
    // producer there is outside VR.
    Q2_VR_SenseUISample(btn, ui);
    hands = Q2_VR_SenseTakeEdges(down, up, level, stick);
    if (hands <= 0) {
        vr_note_context(0);
        vr_release_held("no hands (flat)");
        return;
    }

    // CONTEXT 2 IS "MENUS AND CONSOLE, ANY MODE" (charter D5) — and in VR it is wider than
    // `Key_GetDest() & KEY_MENU`. Reaching here in VR at all means the frame is NOT a world
    // frame, so it is a menu, the console, a loading plaque, a demo, a cinematic or a
    // full-screen layout — every one of which wants UI keys and none of which wants +attack.
    // Deciding on KEY_MENU alone sent gameplay binds into a scoreboard on the first sim run.
    const int menu = (VID_iOS_MenuActive() || Q2_VR_Mode() == 2) ? 1 : 0;
    vr_note_context(menu ? 2 : 3);

    // Roles, not sides — the same pair of indices every context uses, hoisted so the menu
    // branch and the flat-gameplay branch cannot disagree about which hand is which.
    const int ai = vr_aim_index(), oi = vr_off_index();

    // R7b item 6 — SKIP THE CINEMATIC. "I had to sit there the whole time. stupid." A tap on
    // the iPhone's glass has always skipped it (main.m's PassiveState branch); in a headset
    // there is no glass to tap, and neither the gamepad nor the Sense pair had any way in.
    //
    // Handled HERE, before the menu/gameplay split, because a cinematic is neither: it is a
    // non-world frame with no menu up, so the split below would route it to the flat-gameplay
    // branch and emit +attack at a movie. Any face button, either trigger, or Start — the same
    // set a gamepad now skips with, so the device checklist is one line and not two.
    // ...and only while no real menu is up: a player who opened the menu DURING the intro
    // still needs Up/Down/Enter, and `menu` below is unconditionally 1 in VR so the
    // predicate has to be the engine's own menu state, not that.
    if (VID_iOS_PassiveState() == 2 && !VID_iOS_MenuActive()) {
        unsigned d = down[0] | down[1];
        if (d & (Q2_SENSE_TRIGGER | Q2_SENSE_A | Q2_SENSE_B | Q2_SENSE_MENU)) {
            VID_iOS_SkipCinematic();
            Q2_VR_UISkipCount++;
            Q2_VR_Log("VRUI skip: a Sense button ended the cinematic");
        }
        return;
    }

    if (menu) {
        // Sticks summed across both hands and thresholded, so either thumb navigates — the
        // gamepad's dpad AND its left stick both navigate too, so summing is the replication
        // and not a shortcut.
        const double now = Sys_Milliseconds() * 0.001;
        float ax = stick[0] + stick[2], ay = stick[1] + stick[3];
        if (fabsf(ax) >= fabsf(ay)) vr_menu_axis(ax, IOS_MENU_RIGHT, IOS_MENU_LEFT, now);
        else                        vr_menu_axis(ay, IOS_MENU_UP, IOS_MENU_DOWN, now);
        // R7b item 7 — BY ROLE, not hand-agnostic. A gamepad's A selects and its B backs; X and
        // Y do nothing in a menu. Making both hands' top face button Back was the "wasted
        // duplicate" that was reported, and it cost the pair its only free element. The AIM
        // hand's trigger keeps Enter as well: it is the one VR affordance in here, it is what
        // a hand reaching at a menu expects, and it collides with nothing.
        //
        // ...UNLESS ONLY ONE HAND IS ANSWERING, and then either hand navigates. A pair whose
        // aim half has a flat battery, or is on the table, or has lost its accessory anchor,
        // is a pair the player still has to be able to reach a menu with — and "the menu will
        // not accept Enter" is the single worst state a headset app can be left in, because
        // the way out of it is the thing that stopped working. Gamepad fidelity is the point
        // of the by-role split, but it is not worth a locked menu, and a one-controller
        // session has no second hand for the role to be distinguishable FROM.
        const unsigned menuDown = (hands <= 1) ? (down[0] | down[1]) : down[ai];
        if (menuDown & (Q2_SENSE_TRIGGER | Q2_SENSE_A)) {
            VID_iOS_MenuKey(IOS_MENU_ENTER, true);
            VID_iOS_MenuKey(IOS_MENU_ENTER, false);
            Q2_VR_UIEnterCount++;
        }
        if (menuDown & Q2_SENSE_B) {
            VID_iOS_MenuKey(IOS_MENU_BACK, true);
            VID_iOS_MenuKey(IOS_MENU_BACK, false);
            Q2_VR_UIEscCount++;
        }
        // AND THE SAME EXCEPTION, INVERTED, so the solo fallback does not double-emit. With
        // both hands answering, the off hand's top face button is Start (see vr_start_mask).
        // With ONE hand answering it has just been read as Back above, and a press that fired
        // Back AND Start would pop a menu level and then toggle the whole menu shut — one
        // physical press, two logical events, which is the partition rule broken by the very
        // code path added to protect the player. Solo, only the hardware menu button is Start.
        const unsigned menuStart = (hands <= 1) ? ((down[0] | down[1]) & Q2_SENSE_MENU)
                                                : vr_start_mask(down[ai], down[oi]);
        if (menuStart) vr_start_press();
        return;
    }

    // FLAT GAMEPLAY (the 2D window and the 3D panel). The pair merges as an ordinary gamepad
    // so it is never dead outside VR: same virtual keys, same analog move bridge, same look
    // bridge, therefore the same binds, the same sensitivity and the same weapon wheel.
    for (int i = 0; i < VR_BTN_KEY_COUNT; i++) {
        if (down[ai] & vr_btn_keys[i].bit) vr_press(i * 2 + 0, vr_btn_keys[i].aimKey, true);
        if (up[ai]   & vr_btn_keys[i].bit) vr_press(i * 2 + 0, vr_btn_keys[i].aimKey, false);
        if (!vr_btn_keys[i].offKey) continue;
        if (down[oi] & vr_btn_keys[i].bit) vr_press(i * 2 + 1, vr_btn_keys[i].offKey, true);
        if (up[oi]   & vr_btn_keys[i].bit) vr_press(i * 2 + 1, vr_btn_keys[i].offKey, false);
    }
    if (vr_start_mask(down[ai], down[oi])) vr_start_press();
    {
        extern void VID_iOS_LookAnalog(float yaw, float pitch);
        extern float VID_iOS_SensX(void);
        extern float VID_iOS_SensY(void);
        extern bool  VID_iOS_InvertY(void);
        float mx = (oi == 0) ? stick[0] : stick[2];
        float my = (oi == 0) ? stick[1] : stick[3];
        float lx = (ai == 0) ? stick[0] : stick[2];
        float ly = (ai == 0) ? stick[1] : stick[3];
        vr_move_latch(mx, my);          // falling edge only — see the note in the world frame
        if (fabsf(lx) < 0.12f) lx = 0;
        if (fabsf(ly) < 0.12f) ly = 0;
        VID_iOS_LookAnalog(lx * VID_iOS_SensX() / 3.0f,
                           (VID_iOS_InvertY() ? -1.0f : 1.0f) * ly * VID_iOS_SensY() / 3.0f);
    }
}

// =====================================================================================
// Dump fields — APPENDED to AIMNOW / VIEWMODELNOW, plus HANDSNOW's own record
// =====================================================================================

void Q2_VR_DumpAimFields(char *out, int outsz)
{
    q2_vr_hand_t h[2];
    pthread_mutex_lock(&hand_lock);
    h[0] = hand_last[0];
    h[1] = hand_last[1];
    pthread_mutex_unlock(&hand_lock);
    const int ai = vr_aim_index();
    Q_snprintf(out, outsz,
               " aimsrc=%s aimhandidx=%d handaim=%d handmiss=%d aimyaw=%.1fdeg "
               "aimpitch=%.1fdeg pitchtrim=%.1fdeg pitchcomp=%d handL=(%.1f,%.1f,%.1f)deg "
               "handR=(%.1f,%.1f,%.1f)deg handLofs=(%.3f,%.3f,%.3f)m "
               "handRofs=(%.3f,%.3f,%.3f)m posed=%d%d sentpitch=%.1fdeg deltapitch=%.1fdeg",
               vr_aim_from_hand ? "hand" : "head", ai, vr_hand_aim_on, vr_hand_miss,
               vr_aim_yaw, vr_aim_pitch, Q2_VR_PitchTrim(), vr_pitch_comp,
               h[0].pitchDeg, h[0].yawDeg, h[0].rollDeg,
               h[1].pitchDeg, h[1].yawDeg, h[1].rollDeg,
               h[0].ofsFwd, h[0].ofsRight, h[0].ofsUp,
               h[1].ofsFwd, h[1].ofsRight, h[1].ofsUp,
               h[0].posed, h[1].posed,
               q2vr.view_pitch_out, q2vr.delta_pitch);
}

void Q2_VR_DumpViewmodelFields(char *out, int outsz)
{
    // R7b item 9 — `vmpivot` is READ BACK OFF THE FINISHED MOUNT, not predicted from the
    // inputs: the engine writes it by subtracting the scaled grip correction from the origin
    // it actually placed the entity at, so a build that scaled about the wrong point reports
    // the wrong number rather than looking fine. (The Q3 port learned this the expensive way;
    // its note is "read the pivot back off the transformed entity".) The claim it makes
    // assertable is exactly the ask: change Weapon Size and this must not move.
    Q_snprintf(out, outsz,
               " handvalid=%d mounted=%d vmorg=(%.1f,%.1f,%.1f)u vmang=(%.1f,%.1f,%.1f)deg "
               "vmpivot=(%.1f,%.1f,%.1f)u "
               "handofs=(%.1f,%.1f,%.1f)u grip=(%.2f,%.2f,%.2f)u gripang=(%.1f,%.1f,%.1f)deg "
               "wepscale=%.2f weprow=%.2f dot=%d dotdrawn=%d dotrange=%.0fu dotscale=%.2f",
               q2vr.hand_valid, q2vr.vm_mounted,
               q2vr.vm_org[0], q2vr.vm_org[1], q2vr.vm_org[2],
               q2vr.vm_ang[0], q2vr.vm_ang[1], q2vr.vm_ang[2],
               q2vr.vm_pivot[0], q2vr.vm_pivot[1], q2vr.vm_pivot[2],
               q2vr.hand_ofs[0], q2vr.hand_ofs[1], q2vr.hand_ofs[2],
               vr_grip[0], vr_grip[1], vr_grip[2],
               vr_grip_ang[0], vr_grip_ang[1], vr_grip_ang[2],
               q2vr.weapon_scale, Q2_VR_WeaponSizeRow(),
               q2vr.aim_dot, q2vr.dot_drawn, q2vr.dot_range, Q2_VR_DotScale());
}

// HANDSNOW: the hardware's own answer, so a device report can separate "no controller",
// "no permission", "aggregate MFi" and "tracked but the game ignored it" without guessing.
void Q2_VR_DumpHands(char *out, int outsz)
{
    unsigned level[2] = {0, 0};
    float stick[4] = {0, 0, 0, 0};
    int hands = Q2_VR_SensePeekLevel(level, stick);
    q2_vr_hand_t h[2];
    uint64_t polls;
    pthread_mutex_lock(&hand_lock);
    h[0] = hand_last[0];
    h[1] = hand_last[1];
    polls = hand_polls;
    pthread_mutex_unlock(&hand_lock);
    Q_snprintf(out, outsz,
               "HANDSNOW vr=%s hands=%d polls=%llu controllers=%s tracking=%s auth=%d "
               "loadfail=%d anchors=%d presentL=%d presentR=%d posedL=%d posedR=%d "
               "heldL=%d heldR=%d btnL=0x%02x btnR=0x%02x stickL=(%.2f,%.2f) "
               "stickR=(%.2f,%.2f) heldkeys=%d ctx=%d flicks=%d uienter=%d uiesc=%d "
               "uistart=%d uiskip=%d padmap=%s "
               "synth=%d",
               Q2_VR_Mode() == 2 ? "on" : "off", hands, (unsigned long long)polls,
               Q2_VR_SenseStatusControllers(), Q2_VR_SenseStatusTracking(),
               Q2_VR_SenseAuthState(), Q2_VR_SenseLoadFailCode(), Q2_VR_SenseAnchorCount(),
               h[0].present, h[1].present, h[0].posed, h[1].posed, h[0].held, h[1].held,
               level[0], level[1], stick[0], stick[1], stick[2], stick[3],
               vr_held_count, vr_last_ctx, vr_turns_flick,
               Q2_VR_UIEnterCount, Q2_VR_UIEscCount,
               Q2_VR_UIStartCount, Q2_VR_UISkipCount,
               // R7b item 7 — THE MAP ITSELF, in the dump. The ask was that the pair BE a
               // gamepad; a counter proves a press arrived, but only naming the routing proves
               // it arrived as the right thing. Aim/off, then the element order of vr_btn_keys,
               // then what carries Start. A build whose table drifts says so here.
               "aimTRG.rtrigger_GRP.rshoulder_A.abtn_B.bbtn_STK.rstick"
               "+offTRG.ltrigger_GRP.lshoulder_A.xbtn_B.START_STK.lstick+menu.START",
               Q2_VR_SenseSynthActive());
}

// =====================================================================================
// Console surface
// =====================================================================================

static void Cmd_VRGrip_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrgrip fwd=%.2f right=%.2f up=%.2f pitch=%.1f yaw=%.1f roll=%.1f (units, degrees)\n",
                   vr_grip[0], vr_grip[1], vr_grip[2],
                   vr_grip_ang[0], vr_grip_ang[1], vr_grip_ang[2]);
        Q2_VR_ConPrintf("usage: q2vrgrip <fwd> | q2vrgrip <fwd> <right> <up> [pitch] [yaw] [roll] | q2vrgrip reset\n");
        Q2_VR_ConPrintf("       session-only; drag it live in the headset and read the answer back here.\n");
        return;
    }
    if (!Q_stricmp(Cmd_Argv(1), "reset")) {
        vr_grip_defaults();
        Q2_VR_ConPrintf("VRSET grip reset to fwd=%.2f right=%.2f up=%.2f\n",
                   vr_grip[0], vr_grip[1], vr_grip[2]);
        return;
    }
    // A typo must be REFUSED, not read as zero: a silent 0 moves the gun and looks like a
    // legitimate answer, and the tuning session then chases a number nobody typed.
    char *end = NULL;
    double v = strtod(Cmd_Argv(1), &end);
    if (end == Cmd_Argv(1) || !isfinite(v)) { Q2_VR_ConPrintf("q2vrgrip: '%s' is not a number\n", Cmd_Argv(1)); return; }
    vr_grip[0] = Q_clipf((float)v, -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
    if (Cmd_Argc() >= 4) {
        vr_grip[1] = Q_clipf((float)atof(Cmd_Argv(2)), -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
        vr_grip[2] = Q_clipf((float)atof(Cmd_Argv(3)), -VR_GRIP_OFF_LIMIT, VR_GRIP_OFF_LIMIT);
    }
    if (Cmd_Argc() >= 7) {
        vr_grip_ang[0] = Q_clipf((float)atof(Cmd_Argv(4)), -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
        vr_grip_ang[1] = Q_clipf((float)atof(Cmd_Argv(5)), -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
        vr_grip_ang[2] = Q_clipf((float)atof(Cmd_Argv(6)), -VR_GRIP_ANG_LIMIT, VR_GRIP_ANG_LIMIT);
    }
    Q2_VR_ConPrintf("VRSET grip fwd=%.2f right=%.2f up=%.2f pitch=%.1f yaw=%.1f roll=%.1f\n",
               vr_grip[0], vr_grip[1], vr_grip[2],
               vr_grip_ang[0], vr_grip_ang[1], vr_grip_ang[2]);
}

static void Cmd_VRHandAim_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrhandaim %d\n", vr_hand_aim_on); return; }
    vr_hand_aim_on = atoi(Cmd_Argv(1)) != 0;
    Q2_VR_ConPrintf("VRSET handaim=%d\n", vr_hand_aim_on);
}

static void Cmd_VRPitchComp_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrpitchcomp %d\n", vr_pitch_comp); return; }
    vr_pitch_comp = atoi(Cmd_Argv(1)) != 0;
    Q2_VR_ConPrintf("VRSET pitchcomp=%d\n", vr_pitch_comp);
}

static void Cmd_VRHandCtx_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrhandctx %d\n", vr_ctx_handoff); return; }
    vr_ctx_handoff = atoi(Cmd_Argv(1)) != 0;
    Q2_VR_ConPrintf("VRSET handctx=%d\n", vr_ctx_handoff);
}

static void Cmd_VRFlick_f(void)
{
    if (Cmd_Argc() < 2) { Q2_VR_ConPrintf("q2vrflick %d flicks=%d\n", vr_flick_on, vr_turns_flick); return; }
    vr_flick_on = atoi(Cmd_Argv(1)) != 0;
    vr_flick_armed = 1;
    Q2_VR_ConPrintf("VRSET flick=%d\n", vr_flick_on);
}

static void Cmd_VRDot_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("q2vrdot on=%d scale=%.2f row=%.2f override=%.2f drawn=%d range=%.0fu\n",
                   vr_dot_on, Q2_VR_DotScale(), Q2_VR_CrosshairSize(), vr_dot_scale,
                   q2vr.dot_drawn, q2vr.dot_range);
        Q2_VR_ConPrintf("usage: q2vrdot <0|1> [scale 0.25..4, or 0 to follow Crosshair Size]\n");
        return;
    }
    vr_dot_on = atoi(Cmd_Argv(1)) != 0;
    if (Cmd_Argc() > 2) {
        const float v = (float)atof(Cmd_Argv(2));
        vr_dot_scale = v <= 0.0f ? 0.0f : Q_clipf(v, 0.25f, 4.0f);
    }
    Q2_VR_ConPrintf("VRSET dot=%d scale=%.2f override=%.2f\n",
               vr_dot_on, Q2_VR_DotScale(), vr_dot_scale);
}

static void Cmd_VRHaptic_f(void)
{
    if (Cmd_Argc() < 2) {
        Q2_VR_ConPrintf("usage: q2vrhaptic <l|r> [strength 0..1] [duration s]\n");
        return;
    }
    int h = (!Q_stricmp(Cmd_Argv(1), "r") || !Q_stricmp(Cmd_Argv(1), "right")) ? 1 : 0;
    float s = Cmd_Argc() > 2 ? Q_clipf((float)atof(Cmd_Argv(2)), 0.0f, 1.0f) : 0.7f;
    float d = Cmd_Argc() > 3 ? Q_clipf((float)atof(Cmd_Argv(3)), 0.0f, 1.0f) : 0.03f;
    Q2_VR_Haptic(h, s, d, "console");
    Q2_VR_ConPrintf("VRHAPTIC requested hand=%s str=%.2f dur=%.3fs (the log line says what happened)\n",
               h ? "r" : "l", s, d);
}

static void Cmd_VRDoff_f(void)
{
    Q2_VR_SenseForceDoff();
    Q2_VR_ConPrintf("VRINJECT doff: both hands dropped; the next input frame must release everything\n");
}

void Q2_VR_RegisterHandCommands(void)
{
    Cmd_AddCommand("q2vrgrip",      Cmd_VRGrip_f);
    Cmd_AddCommand("q2vrhandaim",   Cmd_VRHandAim_f);
    Cmd_AddCommand("q2vrpitchcomp", Cmd_VRPitchComp_f);
    Cmd_AddCommand("q2vrhandctx",   Cmd_VRHandCtx_f);
    Cmd_AddCommand("q2vrflick",     Cmd_VRFlick_f);
    Cmd_AddCommand("q2vrdot",       Cmd_VRDot_f);
    Cmd_AddCommand("q2vrhaptic",    Cmd_VRHaptic_f);
    Cmd_AddCommand("q2vrdoff",      Cmd_VRDoff_f);
    Q2_VR_SenseStart();
}

#endif // Q2_XR_UI
