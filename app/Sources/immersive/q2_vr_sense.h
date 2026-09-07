// q2_vr_sense.h — the PSVR2 Sense hardware layer (charter D5 / guide 12.6).
//
// This header is the boundary between "what the hardware said" and "what the game does with
// it". Nothing above this line knows about GameController, ARKit or CoreHaptics; nothing
// below it knows about Quake units, body yaw or usercmds. The synthetic injection commands
// write the SAME struct the real poll fills, which is the whole reason a simulator run can
// exercise the shipping transform chain instead of a parallel one.
#pragma once
#include <stdint.h>
#include <simd/simd.h>

// The button bits. These are the SAME values `q2_vr_dumps.m` has printed since R0 (trigger,
// grip, a, b, stick, menu) — the injection command's vocabulary and the driver's bitmask are
// one thing, so a suite line and a device log read identically.
enum {
    Q2_SENSE_TRIGGER = 1u << 0,
    Q2_SENSE_GRIP    = 1u << 1,
    Q2_SENSE_A       = 1u << 2,
    Q2_SENSE_B       = 1u << 3,
    Q2_SENSE_STICK   = 1u << 4,
    Q2_SENSE_MENU    = 1u << 5,
};
#define Q2_SENSE_BUTTON_COUNT 6

// One hand, exactly as the poll found it. `originFromHand` is RAW ARKit tracking space: the
// conversion into the game's frame happens in one place (q2_vr_hands.m) so there is exactly
// one named aim frame in the port, which is the lesson three donor bugs share.
typedef struct {
    int  present;                   // a controller is assigned to this hand
    int  posed;                     // ARKit (or an injection) gave it a pose this poll
    int  held;                      // the anchor says it is in a hand, not on a table
    unsigned buttons;               // Q2_SENSE_* bitmask
    float trigger, grip;            // analog 0..1 (the trigger's travel is on the BUTTON)
    float stickX, stickY;           // -1..1
    simd_float4x4 originFromHand;   // tracking space, identity when !posed
} q2_vr_sense_hand_t;

#ifdef __cplusplus
extern "C" {
#endif

// Start discovery. Idempotent, safe from any thread, and safe to call before the engine has
// come up (the gamepad filter reaches it from the very first poll).
void Q2_VR_SenseStart(void);

// THE POLL OUTPUT BOUNDARY. Fills both hands: buttons and sticks from GameController, poses
// from the accessory-tracking provider, then the synthetic override on top. Called from the
// compositor thread once per published frame.
void Q2_VR_SensePoll(q2_vr_sense_hand_t out[2]);

// Buttons and sticks ONLY, deliberately without ARKit — the UI pump needs the pair to work in
// the 2D window and on the 3D panel, where there is no compositor frame and no pose to speak
// of. Returns how many hands answered, so the caller can drop its edge state rather than
// latch a phantom. `stick` is [lx, ly, rx, ry].
int  Q2_VR_SenseUISample(unsigned btn[2], float stick[4]);

// THE ONE EDGE DETECTOR (charter D5, guide 15 #25). It lives HERE, under the same lock the
// poll publishes through, because that is the only place both producers — the compositor's
// per-frame poll and the UI sample that runs when there is no compositor — can fold into one
// accumulator. Edges are OR-accumulated and cleared only by a DRAIN, so a tap that begins and
// ends between two consumer frames still lands exactly once; `level` and the sticks come back
// from the same poll, so a consumer can never pair this frame's stick with last frame's
// button. Returns the number of hands that answered — 0 means release everything rather than
// latch a phantom.
int  Q2_VR_SenseTakeEdges(unsigned down[2], unsigned up[2], unsigned level[2], float stick[4]);
// Read WITHOUT draining, for the dumps: an instrument that consumed the thing it reports on
// would make every assertion that follows it wrong.
int  Q2_VR_SensePeekLevel(unsigned level[2], float stick[4]);
// Context handoff: forget the pending edges but KEEP the held level, so a trigger held across
// a gameplay/menu boundary neither re-fires on the other side nor emits a release nobody
// pressed. This is the exact shape of the donors' bug #25, expressed as a function.
void Q2_VR_SenseRebaseEdges(void);

// The one-fist filter (charter D5 context 3). The SAME `SpatialGamepad` declaration that makes
// the pair trackable makes the ordinary gamepad layer adopt each half as its own pad, and
// `GCController.controllers.firstObject` then drives the whole game from one hand. Conservative
// by construction: it fires only when a SPATIAL controller carries this name AND no ordinary
// one does, so an ordinary pad can never be taken away by a name collision.
int  Q2_VR_SenseShouldIgnoreGamepad(const char *name);
// How many ordinary (non-spatial) controllers are connected. The touch layer asks this
// instead of `GCController.controllers.count`, which counts Sense halves.
int  Q2_VR_SenseOrdinaryPadCount(void);
// 1 while at least one hand has a controller assigned (used for the flat merge).
int  Q2_VR_SenseConnected(void);

// Haptics. `dur` <= 0.04 s becomes a TRANSIENT: a 20 ms continuous event on these actuators
// is a twentieth of a second of faint hum, which reads as no haptic at all. The engine calls
// the forwarder, which honours the Controller Haptics row and logs every pulse.
void Q2_VR_SenseHaptic(int hand, float strength, float duration, const char *why);
void Q2_VR_Haptic(int hand, float strength, float duration, const char *why);

// Status, for HANDSNOW and the device report. Static buffers; call from one thread.
const char *Q2_VR_SenseStatusControllers(void);
const char *Q2_VR_SenseStatusTracking(void);
int         Q2_VR_SenseAuthState(void);      // 0 pending, 1 allowed, -1 denied
int         Q2_VR_SenseLoadFailCode(void);
int         Q2_VR_SenseAnchorCount(void);

// Synthetic injection, written by `q2vrhand` / `q2vrhandbtn` / `q2vrhandstick`. Latched, so
// holds compose; a one-shot that auto-releases re-arms every edge detector downstream.
void Q2_VR_SenseSetSynthHand(int hand, int on, float yaw, float pitch, float roll,
                             float x, float y, float z);
void Q2_VR_SenseSetSynthButtons(int hand, unsigned buttons);
void Q2_VR_SenseSetSynthStick(int hand, float x, float y);
int  Q2_VR_SenseSynthActive(void);
// The doff/disconnect fault injector: drops every hand exactly as a disconnect does, so the
// release-on-doff invariant is provable without a headset to take off.
void Q2_VR_SenseForceDoff(void);

#ifdef __cplusplus
}
#endif
