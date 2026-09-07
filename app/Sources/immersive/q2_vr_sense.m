// q2_vr_sense.m — PSVR2 Sense controllers on visionOS (charter D5, guide 12.6).
//
// TWO QUESTIONS, KEPT APART, because conflating them cost the donors days:
//
//   WHO DRIVES INPUT — a product-category question. Spatial-category controllers are ours;
//   every ordinary gamepad stays with `pollController` and the player's own binds. The
//   gamepad filter (`main.m`) asks THIS file the same question, so the two halves cannot
//   disagree about who owns a device.
//
//   WHERE THE HAND IS — an ARKit question, and NOT the same gate.
//   `ar_accessory_load_from_device` takes a GCDevice, not a spatial controller: a device that
//   is "just a gamepad" for input may still be trackable. So the load is attempted for EVERY
//   controller and the result is logged either way.
//
// THE TRAP LEDGER, inherited from both donors and not paid for again here:
//   - DECLARATION AND FILTER SHIP TOGETHER. Without `SpatialGamepad` in
//     `GCSupportedGameControllers` the pair enumerates as ONE aggregate MFi gamepad and the
//     accessory load fails with code 1200. With it, two `GCProductCategorySpatialController`
//     devices appear — and `GCController.controllers.firstObject` becomes a Sense half, which
//     is the game being driven from one fist.
//   - AUTHORIZATION BEFORE LOAD. A load issued without accessory-tracking authorization fails
//     in exactly the shape of "this hardware cannot be tracked", which is the most misleading
//     result available. Ask first, PARK devices that connect while the user decides, then
//     drain the queue.
//   - ELEMENT NAMES ARE NOT GUESSED. The constants below are the verified ones; each also has
//     a by-shape fallback, so a naming surprise degrades one button instead of killing the
//     pad. The full inventory is logged on every connect, into the headset-readable black box,
//     because the person who can produce it is wearing a Vision Pro and not sitting at a Mac.
//   - THE UPDATE HANDLER IS NOT OPTIONAL. ARKit's own header: "routine anchor updates will be
//     disabled unless a handler is provided". A provider polled with
//     `get_latest_anchors` and no handler installed is a provider that reports nothing, and
//     the symptom is indistinguishable from a controller that is not tracked.
//   - A working path is never removed in the build that introduces its replacement.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>
#import <CoreHaptics/CoreHaptics.h>
#include <pthread.h>
#include <math.h>
#include <string.h>

#include "q2_vr_sense.h"

extern void Q2_VR_BlackBoxPin(const char *key, const char *line);
extern void Q2_VR_BlackBoxLog(const char *line);
extern void Q2_VR_Log(const char *msg);
extern int  Q2_VR_HapticsOn(void);

#define Q2_SENSE_MAX 4

static void q2_sense_pin(const char *key, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void q2_sense_pin(const char *key, NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (key) Q2_VR_BlackBoxPin(key, s.UTF8String);
    Q2_VR_Log(s.UTF8String);
}

// ---------------------------------------------------------------------------------------
// State. GameController notifications land on the main queue; the poll runs on the
// compositor thread. ONE lock covers the accessory table and the hand assignment.
// ---------------------------------------------------------------------------------------
static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;

static GCController *sHand[2];                      // 0 = left, 1 = right, by ARKit chirality
static NSMutableArray<GCController *> *sSpatial;
static BOOL sStarted;

API_AVAILABLE(visionos(26.0))
static ar_accessory_t sAccessory[Q2_SENSE_MAX];
static GCController  *sAccessoryDevice[Q2_SENSE_MAX];
static int            sAccessoryCount;

API_AVAILABLE(visionos(26.0))
static ar_accessory_tracking_provider_t sProvider;
API_AVAILABLE(visionos(26.0))
static ar_session_t sSession;
static bool sProviderDirty;

static int           sAuthState;        // 0 = pending / not asked, 1 = allowed, -1 = denied
static BOOL          sAuthAsked;
static GCController *sPending[Q2_SENSE_MAX];
static int           sPendingCount;

static int sLoadOK, sLoadFail, sLoadFailCode, sLastAnchorCount, sPollCount;
static int sTrackedMask;

// Synthetic hands. Stored as a FINISHED tracking-space pose so the injection point is
// byte-identical to a real anchor's — the transform chain a simulator run exercises is the
// shipping one, which is the entire design contract of the R0 injection commands.
static int           sSynthOn[2];
static simd_float4x4 sSynthPose[2];
static unsigned      sSynthButtons[2];
static float         sSynthStick[2][2];

// ---------------------------------------------------------------------------------------
// Element access. Spatial controllers are NOT `extendedGamepad` devices, so everything goes
// through `physicalInputProfile` by alias.
// ---------------------------------------------------------------------------------------
static GCControllerButtonInput *q2_btn(GCController *c, NSString *name)
{
    return c ? c.physicalInputProfile.buttons[name] : nil;
}

// By-shape fallback: a button whose alias merely CONTAINS the needle. The verified constant
// is always tried first; this only catches a rename, and it degrades one button rather than
// the pad.
static GCControllerButtonInput *q2_btn_like(GCController *c, NSString *needle)
{
    if (c == nil || needle == nil) return nil;
    for (NSString *k in c.physicalInputProfile.buttons.allKeys)
        if ([k rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound)
            return c.physicalInputProfile.buttons[k];
    return nil;
}

static bool q2_down(GCController *c, NSString *name, NSString *needle)
{
    GCControllerButtonInput *b = q2_btn(c, name);
    if (b == nil) b = q2_btn_like(c, needle);
    return b ? b.isPressed : false;
}

// Analog value. On a Sense the trigger's travel rides on the BUTTON element
// (`pressedInput.value`, which is what `-value` returns here), not on an axis — reading
// `axes` for it is the mistake that produced a digital-feeling trigger on a sibling port.
static float q2_analog(GCController *c, NSString *name, NSString *needle)
{
    GCControllerButtonInput *b = q2_btn(c, name);
    if (b == nil) b = q2_btn_like(c, needle);
    return b ? b.value : 0.0f;
}

// The thumbstick is a DIRECTION PAD, which is why it lives under `dpads` and not `axes`.
static GCControllerDirectionPad *q2_stick(GCController *c)
{
    if (c == nil) return nil;
    GCPhysicalInputProfile *p = c.physicalInputProfile;
    GCControllerDirectionPad *d = p.dpads[GCInputThumbstick];
    if (d != nil) return d;
    for (NSString *k in p.dpads.allKeys) return p.dpads[k];   // better one stick than none
    return nil;
}

static bool q2_is_spatial(GCController *c)
{
    if (@available(visionOS 26.0, *))
        return [c.productCategory isEqualToString:GCProductCategorySpatialController];
    return false;
}

// The name the gamepad layer would know this device by. Matching on anything else would
// compare two different strings and quietly never fire.
static NSString *q2_pad_name(GCController *c)
{
    if (c.vendorName.length) return c.vendorName;
    if (@available(visionOS 26.0, *))
        if (c.productCategory.length) return c.productCategory;
    return @"MFi Gamepad";
}

static unsigned q2_sense_buttons(GCController *c)
{
    unsigned b = 0;
    if (q2_down(c, GCInputTrigger, @"Trigger"))                 b |= Q2_SENSE_TRIGGER;
    if (q2_down(c, GCInputGripButton, @"Grip"))                 b |= Q2_SENSE_GRIP;
    if (q2_down(c, GCInputButtonA, @"Button A"))                b |= Q2_SENSE_A;
    if (q2_down(c, GCInputButtonB, @"Button B"))                b |= Q2_SENSE_B;
    if (q2_down(c, GCInputThumbstickButton, @"Thumbstick Button")) b |= Q2_SENSE_STICK;
    if (q2_down(c, GCInputButtonMenu, @"Menu"))                 b |= Q2_SENSE_MENU;
    return b;
}

// ---------------------------------------------------------------------------------------
// THE ONE EDGE DETECTOR, under the publish lock
// ---------------------------------------------------------------------------------------
// Both polls fold into this: the compositor's per-frame `Q2_VR_SensePoll` and the
// `Q2_VR_SenseUISample` that runs when there is no compositor at all (the 2D window, the 3D
// panel). One accumulator means ONE physical press is ONE impulse no matter which loop
// happens to be beating, and it means a tap that begins and ends between two consumer frames
// is not lost — the edges are OR-accumulated and only a DRAIN clears them.
//
// Buttons follow PRESENCE, not pose. Deafening a momentarily-untracked controller would kill
// every button for a whole session on a headset that declined accessory tracking, which is a
// far worse failure than a hand whose pose is stale for a frame.
static unsigned sEdgeLevel[2], sEdgeDown[2], sEdgeUp[2];
static int      sEdgeHands;
static float    sEdgeStick[4];

static void q2_sense_fold_edges_locked(const unsigned cur[2], int hands, const float stick[4])
{
    for (int h = 0; h < 2; h++) {
        sEdgeDown[h] |= cur[h] & ~sEdgeLevel[h];
        sEdgeUp[h]   |= sEdgeLevel[h] & ~cur[h];
        sEdgeLevel[h] = cur[h];
    }
    for (int i = 0; i < 4; i++) sEdgeStick[i] = stick[i];
    sEdgeHands = hands;
}

int Q2_VR_SenseTakeEdges(unsigned down[2], unsigned up[2], unsigned level[2], float stick[4])
{
    int hands;
    pthread_mutex_lock(&sLock);
    for (int h = 0; h < 2; h++) {
        if (down)  down[h]  = sEdgeDown[h];
        if (up)    up[h]    = sEdgeUp[h];
        if (level) level[h] = sEdgeLevel[h];
        sEdgeDown[h] = sEdgeUp[h] = 0;
    }
    if (stick) for (int i = 0; i < 4; i++) stick[i] = sEdgeStick[i];
    hands = sEdgeHands;
    pthread_mutex_unlock(&sLock);
    return hands;
}

int Q2_VR_SensePeekLevel(unsigned level[2], float stick[4])
{
    int hands;
    pthread_mutex_lock(&sLock);
    for (int h = 0; h < 2; h++) if (level) level[h] = sEdgeLevel[h];
    if (stick) for (int i = 0; i < 4; i++) stick[i] = sEdgeStick[i];
    hands = sEdgeHands;
    pthread_mutex_unlock(&sLock);
    return hands;
}

void Q2_VR_SenseRebaseEdges(void)
{
    pthread_mutex_lock(&sLock);
    for (int h = 0; h < 2; h++) sEdgeDown[h] = sEdgeUp[h] = 0;   // LEVEL is deliberately kept
    pthread_mutex_unlock(&sLock);
}

// ---------------------------------------------------------------------------------------
// Inventory — the deliverable of the first device round, and the reason a name is never
// guessed. Logged into the black box, which is Files-app readable from inside the headset.
// ---------------------------------------------------------------------------------------
static NSMutableString *sInventory;

static void q2_sense_log_inventory(GCController *c)
{
    NSString *cat = @"(unknown)";
    if (@available(visionOS 26.0, *)) cat = c.productCategory ?: @"(nil)";
    q2_sense_pin("sense_dev", @"SENSE controller '%@' category='%@' spatial=%d padname='%@'",
                 c.vendorName ?: @"(nil)", cat, q2_is_spatial(c) ? 1 : 0, q2_pad_name(c));
    q2_sense_pin(NULL, @"SENSE   buttons: %@",
                 [c.physicalInputProfile.buttons.allKeys componentsJoinedByString:@", "]);
    q2_sense_pin(NULL, @"SENSE   axes:    %@",
                 [c.physicalInputProfile.axes.allKeys componentsJoinedByString:@", "]);
    q2_sense_pin(NULL, @"SENSE   dpads:   %@",
                 [c.physicalInputProfile.dpads.allKeys componentsJoinedByString:@", "]);
    q2_sense_pin(NULL, @"SENSE   haptics: %@", c.haptics ? @"yes" : @"no");
    if (sInventory == nil) sInventory = [NSMutableString string];
    [sInventory appendFormat:@"%@ [%@] %lub/%lud%@\n", c.vendorName ?: @"?", cat,
                             (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
                             (unsigned long)c.physicalInputProfile.dpads.allKeys.count,
                             c.haptics ? @" haptics" : @""];
}

// ---------------------------------------------------------------------------------------
// Accessory tracking
// ---------------------------------------------------------------------------------------
API_AVAILABLE(visionos(26.0))
static void q2_sense_load_retry(GCController *c, int attempt);
static void q2_sense_provider_needs_rebuild(void);

API_AVAILABLE(visionos(26.0))
static void q2_sense_load(GCController *c) { q2_sense_load_retry(c, 0); }

API_AVAILABLE(visionos(26.0))
static void q2_sense_load_retry(GCController *c, int attempt)
{
    if (c == nil) return;
    pthread_mutex_lock(&sLock);
    for (int i = 0; i < sAccessoryCount; i++)
        if (sAccessoryDevice[i] == c) {
            pthread_mutex_unlock(&sLock);
            return;                 // already loaded — a device arrives twice (queue + connect)
        }
    pthread_mutex_unlock(&sLock);

    ar_accessory_load_from_device(c, ^(id<GCDevice> device, bool successful,
                                       ar_error_t error, ar_accessory_t accessory) {
        (void)device;
        if (!successful || accessory == NULL) {
            long code = -1;
            CFStringRef desc = NULL;
            if (error != NULL) {
                code = (long)ar_error_get_error_code(error);
                CFErrorRef cfe = ar_error_copy_cf_error(error);
                if (cfe != NULL) { desc = CFErrorCopyDescription(cfe); CFRelease(cfe); }
            }
            sLoadFail++;
            sLoadFailCode = (int)code;
            // 1200 is the accessory-loading failure. On this system it means the
            // SpatialGamepad declaration did not take effect and the pair is still one
            // aggregate MFi device — so the decoder says that, rather than "unknown error".
            q2_sense_pin("sense_load",
                         @"SENSE accessory load FAILED for '%@' code=%ld attempt=%d%@ desc=%@",
                         c.vendorName ?: @"(nil)", code, attempt,
                         code == 1200 ? @"  (1200 = aggregate MFi: the SpatialGamepad declaration is missing or ineffective)" : @"",
                         desc ? (__bridge NSString *)desc : @"(none)");
            if (desc != NULL) CFRelease(desc);
            // ONE retry, 2 s later: accessory tracking is gated on the app being focused, and
            // a load issued during VR entry or a focus change can fail for that alone. Both
            // results are logged, so a retry cannot hide the first answer.
            if (attempt == 0)
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (@available(visionOS 26.0, *)) q2_sense_load_retry(c, 1);
                });
            return;
        }
        pthread_mutex_lock(&sLock);
        if (sAccessoryCount >= Q2_SENSE_MAX) {
            pthread_mutex_unlock(&sLock);
            q2_sense_pin(NULL, @"SENSE accessory table full — ignoring '%s'",
                         ar_accessory_get_name(accessory));
            return;
        }
        // GameController has NO handedness API — the ARKit accessory's inherent chirality is
        // the documented pairing, and it is why input assignment has to wait for an
        // asynchronous answer instead of guessing from a name.
        ar_accessory_chirality_t ch = ar_accessory_get_inherent_chirality(accessory);
        sAccessory[sAccessoryCount] = accessory;
        sAccessoryDevice[sAccessoryCount] = c;
        sAccessoryCount++;
        sLoadOK++;
        sProviderDirty = true;
        if (ch == ar_accessory_chirality_left)       sHand[0] = c;
        else if (ch == ar_accessory_chirality_right) sHand[1] = c;
        pthread_mutex_unlock(&sLock);
        q2_sense_provider_needs_rebuild();
        q2_sense_pin("sense_load",
                     @"SENSE accessory LOADED '%s' chirality=%s from '%@' — %d known",
                     ar_accessory_get_name(accessory),
                     ch == ar_accessory_chirality_left ? "LEFT" :
                     ch == ar_accessory_chirality_right ? "RIGHT" : "unspecified",
                     c.vendorName ?: @"(nil)", sAccessoryCount);
    });
}

API_AVAILABLE(visionos(26.0))
static void q2_sense_request_auth(void)
{
    if (sAuthAsked) return;
    sAuthAsked = YES;
    if (sSession == NULL) sSession = ar_session_create();
    q2_sense_pin("sense_auth", @"SENSE requesting accessory-tracking authorization");
    ar_session_request_authorization(sSession, ar_authorization_type_accessory_tracking,
                                     ^(ar_authorization_results_t results, ar_error_t error) {
        __block int state = -1;
        if (results != NULL)
            ar_authorization_results_enumerate_results(results, ^bool (ar_authorization_result_t r) {
                if (ar_authorization_result_get_authorization_type(r) == ar_authorization_type_accessory_tracking)
                    state = (ar_authorization_result_get_status(r) == ar_authorization_status_allowed) ? 1 : -1;
                return true;
            });
        sAuthState = state;
        q2_sense_pin("sense_auth", @"SENSE accessory-tracking authorization: %s%s",
                     state == 1 ? "ALLOWED" : "DENIED", error ? " (with error)" : "");
        if (state != 1) return;
        // Drain the park queue. Devices that connected while the modal prompt was up are
        // loaded now, in arrival order.
        for (int i = 0; i < sPendingCount; i++) q2_sense_load(sPending[i]);
        sPendingCount = 0;
    });
}

// ---------------------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------------------
static void q2_sense_adopt(GCController *c)
{
    if (c == nil) return;
    q2_sense_log_inventory(c);
    if (q2_is_spatial(c)) {
        pthread_mutex_lock(&sLock);
        if (sSpatial == nil) sSpatial = [NSMutableArray array];
        if (![sSpatial containsObject:c]) [sSpatial addObject:c];
        // Assign provisionally so BUTTONS work before the asynchronous chirality answer
        // lands: a menu that cannot be dismissed until ARKit finishes is a worse failure than
        // a left/right swap for one second, and the load's answer overwrites this.
        pthread_mutex_unlock(&sLock);
    }
    // Poses are asked for on EVERY controller, spatial or not — see the header.
    if (@available(visionOS 26.0, *)) {
        q2_sense_request_auth();
        if (sAuthState == 1)
            q2_sense_load(c);
        else if (sAuthState == 0 && sPendingCount < Q2_SENSE_MAX)
            sPending[sPendingCount++] = c;      // parked until the grant lands
    }
}

// Release-on-doff. There is no doff sensor: taking a controller off surfaces as a disconnect,
// and losing tracking surfaces as an untracked anchor. Both drop the hand here (or at the
// poll), and the ENGINE releases every button once for a hand that stopped answering — a
// publish-side invariant, not a shutdown path, so a controller that dies mid-fire cannot
// leave +attack latched.
static void q2_sense_forget(GCController *c)
{
    pthread_mutex_lock(&sLock);
    for (int i = 0; i < 2; i++)
        if (sHand[i] == c) {
            sHand[i] = nil;
            // Push REAL release edges rather than letting the level go quiet: a battery that
            // dies mid-fire must not leave +attack latched, and the release has to travel
            // through the same detector every other release does or the consumer's own
            // bookkeeping is left believing the key is still down.
            sEdgeUp[i] |= sEdgeLevel[i];
            sEdgeLevel[i] = 0;
            sEdgeDown[i] = 0;
        }
    [sSpatial removeObject:c];
    for (int i = 0; i < sPendingCount; i++)
        if (sPending[i] == c) {
            for (int j = i; j < sPendingCount - 1; j++) sPending[j] = sPending[j + 1];
            sPending[--sPendingCount] = nil;
            break;
        }
    if (@available(visionOS 26.0, *)) {
        for (int i = 0; i < sAccessoryCount; i++)
            if (sAccessoryDevice[i] == c) {
                for (int j = i; j < sAccessoryCount - 1; j++) {
                    sAccessory[j] = sAccessory[j + 1];
                    sAccessoryDevice[j] = sAccessoryDevice[j + 1];
                }
                sAccessoryCount--;
                sAccessory[sAccessoryCount] = NULL;
                sAccessoryDevice[sAccessoryCount] = nil;
                sProviderDirty = true;
                break;
            }
    }
    pthread_mutex_unlock(&sLock);
    q2_sense_provider_needs_rebuild();
    q2_sense_pin("sense_dev", @"SENSE controller disconnected ('%@')", c.vendorName ?: @"(nil)");
}

void Q2_VR_SenseStart(void)
{
    if (sStarted) return;
    sStarted = YES;
    for (GCController *c in GCController.controllers) q2_sense_adopt(c);
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        q2_sense_adopt((GCController *)n.object);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification
                                                    object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        q2_sense_forget((GCController *)n.object);
    }];
    // Logged at START, not only on a connect: the simulator has no controllers at all, so
    // "did the SpatialGamepad declaration survive plist processing into the BUILT product"
    // would otherwise be unanswerable there — and that is the one claim the sim CAN prove.
    q2_sense_pin("sense_bundle",
                 @"SENSE backend ready (%lu controller(s)) — bundle GCSupportedGameControllers = %@",
                 (unsigned long)GCController.controllers.count,
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"GCSupportedGameControllers"] ?: @"(ABSENT)");
    q2_sense_pin("sense_bundle2", @"SENSE bundle NSAccessoryTrackingUsageDescription = %@",
                 [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSAccessoryTrackingUsageDescription"] ?: @"(ABSENT)");
}

// ---------------------------------------------------------------------------------------
// The one-fist filter
// ---------------------------------------------------------------------------------------
int Q2_VR_SenseShouldIgnoreGamepad(const char *name)
{
    if (name == NULL) return 0;
    Q2_VR_SenseStart();
    @autoreleasepool {
        NSString *want = [NSString stringWithUTF8String:name];
        BOOL spatial = NO, ordinary = NO;
        for (GCController *c in GCController.controllers) {
            if (![q2_pad_name(c) isEqualToString:want]) continue;
            if (q2_is_spatial(c)) spatial = YES; else ordinary = YES;
        }
        static NSMutableSet *logged;
        if (logged == nil) logged = [NSMutableSet set];
        if (![logged containsObject:want]) {
            [logged addObject:want];
            q2_sense_pin("sense_filter", @"SENSE pad filter: '%@' spatial=%d ordinary=%d -> %@",
                         want, spatial, ordinary,
                         (spatial && !ordinary) ? @"IGNORED as a gamepad (the Sense stack owns it)"
                                                : @"kept as an ordinary gamepad");
        }
        return (spatial && !ordinary) ? 1 : 0;
    }
}

int Q2_VR_SenseOrdinaryPadCount(void)
{
    @autoreleasepool {
        int n = 0;
        for (GCController *c in GCController.controllers)
            if (!q2_is_spatial(c)) n++;
        return n;
    }
}

int Q2_VR_SenseConnected(void)
{
    int n;
    pthread_mutex_lock(&sLock);
    n = (sHand[0] != nil) + (sHand[1] != nil);
    pthread_mutex_unlock(&sLock);
    return n + (sSynthOn[0] || sSynthOn[1] ? 1 : 0);
}

// ---------------------------------------------------------------------------------------
// Provider lifecycle
// ---------------------------------------------------------------------------------------
// NEVER called from the compositor thread. `ar_session_run` is a synchronous ARKit call of
// unbounded duration; running it from inside the per-frame poll (with the state lock held, as
// the first draft of the donor did) would stall a compositor frame AND block the main queue's
// connect handling behind it. The accessory set only changes on a connect, a disconnect or a
// load completing — all main-queue events — so the rebuild belongs there and the poll simply
// reads whatever provider is published right now.
API_AVAILABLE(visionos(26.0))
static void q2_sense_rebuild_provider(void)
{
    ar_accessories_t set = NULL;
    int n = 0;

    pthread_mutex_lock(&sLock);
    sProviderDirty = false;
    n = sAccessoryCount;
    if (n > 0) {
        set = ar_accessories_create();
        for (int i = 0; i < n; i++)
            if (sAccessory[i] != NULL) ar_accessories_add_accessory(set, sAccessory[i]);
    }
    pthread_mutex_unlock(&sLock);

    if (n == 0) {
        pthread_mutex_lock(&sLock);
        sProvider = NULL;
        pthread_mutex_unlock(&sLock);
        return;
    }
    ar_accessory_tracking_configuration_t cfg = ar_accessory_tracking_configuration_create();
    ar_accessory_tracking_configuration_set_accessories(cfg, set);
    // The SAME session the authorization was granted on — a fresh one would be unauthorized
    // again. And a SEPARATE session from the VR loop's world tracking, deliberately:
    // accessories load asynchronously and controllers come and go, while the world provider is
    // created once at loop start. If this session never runs, the world is exactly as it was
    // and only the hands are missing.
    if (sSession == NULL) sSession = ar_session_create();
    ar_accessory_tracking_provider_t p = ar_accessory_tracking_provider_create(cfg);
    // NOT optional (ARKit's own header): "routine anchor updates will be disabled unless a
    // handler is provided". Without this the provider we then poll with get_latest_anchors
    // reports nothing, and the symptom is indistinguishable from a controller that is simply
    // not being tracked — which is the most expensive kind of wrong answer this file can give.
    ar_accessory_tracking_provider_set_update_handler(p, dispatch_get_main_queue(),
        ^(ar_accessory_anchors_t added, ar_accessory_anchors_t updated,
          ar_accessory_anchors_t removed) {
        (void)added; (void)updated; (void)removed;   // the poll reads the latest set itself
    });
    ar_data_providers_t providers = ar_data_providers_create_with_data_providers(p, NULL);
    ar_session_run(sSession, providers);
    pthread_mutex_lock(&sLock);
    sProvider = p;
    pthread_mutex_unlock(&sLock);
    q2_sense_pin("sense_track", @"SENSE accessory tracking running with %d accessory(s)", n);
}

// Coalesced by the dirty flag, so a burst of connects costs one session run.
static void q2_sense_provider_needs_rebuild(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(visionOS 26.0, *)) {
            bool want;
            pthread_mutex_lock(&sLock);
            want = sProviderDirty;
            pthread_mutex_unlock(&sLock);
            if (want) q2_sense_rebuild_provider();
        }
    });
}

// ---------------------------------------------------------------------------------------
// The per-frame poll — THE OUTPUT BOUNDARY
// ---------------------------------------------------------------------------------------
static simd_float4x4 q2_synth_matrix(float yawDeg, float pitchDeg, float rollDeg,
                                     float x, float y, float z)
{
    const float d2r = (float)M_PI / 180.0f;
    float cy = cosf(yawDeg * d2r), sy = sinf(yawDeg * d2r);
    float cp = cosf(pitchDeg * d2r), sp = sinf(pitchDeg * d2r);
    float cr = cosf(rollDeg * d2r), sr = sinf(rollDeg * d2r);
    simd_float4x4 ry = matrix_identity_float4x4, rx = matrix_identity_float4x4,
                  rz = matrix_identity_float4x4, m;
    ry.columns[0] = simd_make_float4(cy, 0, -sy, 0);
    ry.columns[2] = simd_make_float4(sy, 0,  cy, 0);
    rx.columns[1] = simd_make_float4(0, cp,  sp, 0);
    rx.columns[2] = simd_make_float4(0, -sp, cp, 0);
    rz.columns[0] = simd_make_float4(cr, sr, 0, 0);
    rz.columns[1] = simd_make_float4(-sr, cr, 0, 0);
    m = simd_mul(ry, simd_mul(rx, rz));
    m.columns[3] = simd_make_float4(x, y, z, 1.0f);
    return m;
}

void Q2_VR_SensePoll(q2_vr_sense_hand_t out[2])
{
    memset(out, 0, 2 * sizeof(q2_vr_sense_hand_t));
    out[0].originFromHand = out[1].originFromHand = matrix_identity_float4x4;

    // --- buttons and sticks ------------------------------------------------------------
    GCController *hands[2];
    pthread_mutex_lock(&sLock);
    hands[0] = sHand[0];
    hands[1] = sHand[1];
    pthread_mutex_unlock(&sLock);
    for (int h = 0; h < 2; h++) {
        GCController *c = hands[h];
        if (c == nil) continue;
        out[h].present = 1;
        out[h].buttons = q2_sense_buttons(c);
        out[h].trigger = q2_analog(c, GCInputTrigger, @"Trigger");
        out[h].grip    = q2_analog(c, GCInputGripButton, @"Grip");
        GCControllerDirectionPad *d = q2_stick(c);
        if (d) { out[h].stickX = d.xAxis.value; out[h].stickY = d.yAxis.value; }
    }

    // --- poses --------------------------------------------------------------------------
    if (@available(visionOS 26.0, *)) {
        ar_accessory_tracking_provider_t provider;
        bool dirty;
        pthread_mutex_lock(&sLock);
        provider = sProvider;
        dirty = sProviderDirty;
        pthread_mutex_unlock(&sLock);
        if (dirty) q2_sense_provider_needs_rebuild();   // on MAIN, never here

        if (provider != NULL) {
            ar_accessory_anchors_t anchors = ar_accessory_tracking_provider_get_latest_anchors(provider);
            if (anchors != NULL) {
                sLastAnchorCount = (int)ar_accessory_anchors_get_count(anchors);
                __block q2_vr_sense_hand_t *o = out;
                ar_accessory_anchors_enumerate_anchors(anchors, ^bool (ar_accessory_anchor_t anchor) {
                    if (!ar_accessory_anchor_is_tracked(anchor)) return true;
                    // Chirality can be unspecified (a controller on a table is in nobody's
                    // hand). HELD is preferred; the accessory's INHERENT chirality is the
                    // fallback, which a left/right pair always has. Guessing from position is
                    // not a fallback, it is a coin toss with a plausible-sounding name.
                    ar_accessory_chirality_t ch = ar_accessory_anchor_get_held_chirality(anchor);
                    int hand = -1;
                    if (ch == ar_accessory_chirality_left)       hand = 0;
                    else if (ch == ar_accessory_chirality_right) hand = 1;
                    else {
                        ar_accessory_t acc = ar_accessory_anchor_get_accessory(anchor);
                        if (acc != NULL) {
                            ar_accessory_chirality_t inh = ar_accessory_get_inherent_chirality(acc);
                            if (inh == ar_accessory_chirality_left)       hand = 0;
                            else if (inh == ar_accessory_chirality_right) hand = 1;
                        }
                    }
                    if (hand < 0) return true;
                    o[hand].posed = 1;
                    o[hand].present = 1;
                    o[hand].held = ar_accessory_anchor_is_held(anchor) ? 1 : 0;
                    o[hand].originFromHand = ar_accessory_anchor_get_origin_from_anchor_transform(anchor);
                    return true;
                });
            }
        }
    }

    // --- synthetic override (simulator) --------------------------------------------------
    for (int h = 0; h < 2; h++) {
        if (!sSynthOn[h]) continue;
        out[h].posed = 1;
        out[h].present = 1;
        out[h].held = 1;
        out[h].originFromHand = sSynthPose[h];
        out[h].buttons |= sSynthButtons[h];
        out[h].trigger = (sSynthButtons[h] & Q2_SENSE_TRIGGER) ? 1.0f : out[h].trigger;
        out[h].grip    = (sSynthButtons[h] & Q2_SENSE_GRIP)    ? 1.0f : out[h].grip;
        out[h].stickX = sSynthStick[h][0];
        out[h].stickY = sSynthStick[h][1];
    }

    // Fold into the ONE edge detector, under the publish lock, with the sticks from THIS
    // poll. Presence, not pose — see the accumulator's own note.
    {
        unsigned cur[2];
        float stick[4];
        int hands = 0;
        for (int h = 0; h < 2; h++) {
            cur[h] = out[h].present ? out[h].buttons : 0u;
            if (out[h].present) hands++;
        }
        stick[0] = out[0].stickX; stick[1] = out[0].stickY;
        stick[2] = out[1].stickX; stick[3] = out[1].stickY;
        pthread_mutex_lock(&sLock);
        q2_sense_fold_edges_locked(cur, hands, stick);
        pthread_mutex_unlock(&sLock);
    }

    sTrackedMask = (out[0].posed ? 1 : 0) | (out[1].posed ? 2 : 0);
    sPollCount++;
}

// Buttons and sticks only, deliberately without ARKit: the UI pump needs the pair to work in
// the 2D window and on the 3D panel, neither of which has a compositor frame, an alignment or
// a pose. A menu does not care where your hand is, and asking the accessory-tracking provider
// from the game thread once per host frame would be paying for an answer nobody reads.
int Q2_VR_SenseUISample(unsigned btn[2], float stick[4])
{
    @autoreleasepool {
        if (!btn || !stick) return 0;
        GCController *hands[2];
        int n = 0;
        btn[0] = btn[1] = 0u;
        stick[0] = stick[1] = stick[2] = stick[3] = 0.0f;
        pthread_mutex_lock(&sLock);
        hands[0] = sHand[0];
        hands[1] = sHand[1];
        pthread_mutex_unlock(&sLock);
        for (int h = 0; h < 2; h++) {
            GCController *c = hands[h];
            if (c != nil) {
                n++;
                btn[h] = q2_sense_buttons(c);
                GCControllerDirectionPad *d = q2_stick(c);
                if (d) { stick[h * 2 + 0] = d.xAxis.value; stick[h * 2 + 1] = d.yAxis.value; }
            }
            // Injected hands answer here too, or the simulator could never test the one path
            // this exists for.
            if (sSynthOn[h]) {
                if (c == nil) n++;
                btn[h] |= sSynthButtons[h];
                stick[h * 2 + 0] = sSynthStick[h][0];
                stick[h * 2 + 1] = sSynthStick[h][1];
            }
        }
        // The SAME accumulator the compositor poll folds into. In VR both run and the second
        // fold is a no-op; outside VR this is the only producer there is, which is why the
        // menu pump works on the 3D panel and in the 2D window at all.
        pthread_mutex_lock(&sLock);
        q2_sense_fold_edges_locked(btn, n, stick);
        pthread_mutex_unlock(&sLock);
        return n;
    }
}

// ---------------------------------------------------------------------------------------
// Haptics — one engine per hand, built off the render thread
// ---------------------------------------------------------------------------------------
// Creating and starting a CHHapticEngine is SYNCHRONOUS and takes milliseconds. Paying that
// inside the frame that fires the shot would show up as a hitch at exactly the worst moment,
// so the engine is built once, asynchronously, on the main queue, and the first pulse that
// finds it missing simply goes unfelt rather than stalling the frame.
static CHHapticEngine *sHapticEngine[2];
static int             sHapticStarting[2];
static int             sHapticSeq;
static double          sHapticLastLog;

// WHY A PULSE DID OR DID NOT ARRIVE, from the log alone. "The call site never ran", "it ran
// and the engine was not up", "there is no controller for that hand" and "it played and was
// too weak to feel" are four hypotheses with one symptom between them, and a device report
// cannot separate them unless every pulse names itself. The throttle covers the ORDINARY case
// only: every failure is logged unthrottled.
static void q2_haptic_log(int hand, float strength, float duration,
                          const char *why, const char *outcome)
{
    // Sys_Milliseconds, not Sys_DoubleTime: q2repro's platform layer exports the former and
    // this file must not be the one that discovers otherwise at link time.
    extern unsigned Sys_Milliseconds(void);
    const double now = Sys_Milliseconds() * 0.001;
    char line[256];
    sHapticSeq++;
    if (now - sHapticLastLog < 0.25 && strcmp(outcome, "played") == 0) return;
    sHapticLastLog = now;
    snprintf(line, sizeof(line), "HAPTIC #%d %s hand=%s str=%.2f dur=%.3fs -> %s",
             sHapticSeq, why ? why : "-", hand ? "right" : "left", strength, duration, outcome);
    // [R7b item 8a] THIS is the line reported sitting on top of the ammo count. It still
    // reaches the console log and the dev bridge — `sim-verify-vr.sh` greps it — but Q2_VR_Log
    // now prints through the notify firewall (Q2_VR_ConPrintf), so it can no longer land in
    // the transparent overlay the engine draws over the HUD.
    //
    // The explicit BlackBoxLog is GONE, not moved: Q2_VR_Log's own emitter already writes the
    // rolling tail, so this pair was putting every haptic line into the black box twice and
    // halving the number of events the ring could hold.
    Q2_VR_Log(line);
}

void Q2_VR_SenseHaptic(int hand, float strength, float duration, const char *why)
{
    if (hand < 0 || hand > 1 || strength <= 0.0f) return;
    GCController *c;
    pthread_mutex_lock(&sLock);
    c = sHand[hand];
    pthread_mutex_unlock(&sLock);
    if (c == nil) {
        q2_haptic_log(hand, strength, duration, why, "NO CONTROLLER for that hand");
        return;
    }

    CHHapticEngine *eng = sHapticEngine[hand];
    if (eng == nil) {
        if (!sHapticStarting[hand]) {
            sHapticStarting[hand] = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                GCDeviceHaptics *h = c.haptics;
                CHHapticEngine *e = h ? [h createEngineWithLocality:GCHapticsLocalityDefault] : nil;
                NSError *err = nil;
                if (e == nil) return;
                [e startAndReturnError:&err];
                if (err) return;
                e.autoShutdownEnabled = YES;
                sHapticEngine[hand] = e;
            });
        }
        q2_haptic_log(hand, strength, duration, why,
                      "engine not up yet (built asynchronously; this pulse is skipped)");
        return;
    }

    NSError *err = nil;
    CHHapticEventParameter *i =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                      value:strength];
    CHHapticEventParameter *s =
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                      value:0.7f];
    // A TICK is a transient, not a short continuous buzz. Anything at or under ~40 ms on these
    // actuators is close to nothing as a continuous event; the transient is the event type
    // designed for "you touched something" and reads as a crisp tap.
    const BOOL tick = (duration <= 0.04f);
    CHHapticEvent *ev = tick
        ? [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient
                                        parameters:@[i, s] relativeTime:0]
        : [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                        parameters:@[i, s] relativeTime:0 duration:duration];
    CHHapticPattern *pat = [[CHHapticPattern alloc] initWithEvents:@[ev] parameters:@[] error:&err];
    if (err || pat == nil) {
        q2_haptic_log(hand, strength, duration, why, "pattern build FAILED");
        return;
    }
    id<CHHapticPatternPlayer> player = [eng createPlayerWithPattern:pat error:&err];
    if (err || player == nil) {
        q2_haptic_log(hand, strength, duration, why, "player create FAILED");
        return;
    }
    [player startAtTime:0 error:&err];
    q2_haptic_log(hand, strength, duration, why, err ? "start FAILED" : "played");
}

// The name the ENGINE calls. A thin forwarder so no engine code ever learns about
// GameController — and it carries a diagnostic line specifically so a simulator run can
// assert that the call was made, even though the sim has nothing to feel it with.
void Q2_VR_Haptic(int hand, float strength, float duration, const char *why)
{
    if (!Q2_VR_HapticsOn()) {
        q2_haptic_log(hand, strength, duration, why,
                      "SUPPRESSED — Controller Haptics is off in settings");
        return;
    }
    Q2_VR_SenseHaptic(hand, strength, duration, why);
}

// ---------------------------------------------------------------------------------------
// Status
// ---------------------------------------------------------------------------------------
static char sStatusA[192], sStatusB[192];

const char *Q2_VR_SenseStatusControllers(void)
{
    @autoreleasepool {
        NSArray<GCController *> *cs = GCController.controllers;
        if (cs.count == 0) {
            snprintf(sStatusA, sizeof(sStatusA), "none");
            return sStatusA;
        }
        NSMutableString *s = [NSMutableString string];
        int nSpatial = 0;
        for (GCController *c in cs) {
            NSString *cat = @"?";
            if (@available(visionOS 26.0, *)) cat = c.productCategory ?: @"?";
            if (q2_is_spatial(c)) nSpatial++;
            [s appendFormat:@"[%@ %lub/%lud]", cat,
                            (unsigned long)c.physicalInputProfile.buttons.allKeys.count,
                            (unsigned long)c.physicalInputProfile.dpads.allKeys.count];
        }
        snprintf(sStatusA, sizeof(sStatusA), "%lu_pad_%d_spatial_%s",
                 (unsigned long)cs.count, nSpatial, s.UTF8String);
        return sStatusA;
    }
}

const char *Q2_VR_SenseStatusTracking(void)
{
    if (sAuthState == -1)
        snprintf(sStatusB, sizeof(sStatusB), "permission_denied");
    else if (sAuthState == 0)
        snprintf(sStatusB, sizeof(sStatusB), "awaiting_permission%s", sAuthAsked ? "" : "_notasked");
    else if (sLoadOK == 0 && sLoadFail == 0)
        snprintf(sStatusB, sizeof(sStatusB), "allowed_nocontroller");
    else if (sLoadOK == 0)
        snprintf(sStatusB, sizeof(sStatusB), "allowed_%dfail_err%d%s", sLoadFail, sLoadFailCode,
                 sLoadFailCode == 1200 ? "_aggregateMFi" : "");
    else
        snprintf(sStatusB, sizeof(sStatusB), "%dloaded_%danchor_%s%s%s", sLoadOK, sLastAnchorCount,
                 (sTrackedMask & 1) ? "L" : "-", (sTrackedMask & 2) ? "R" : "-",
                 Q2_VR_SenseSynthActive() ? "_synthetic" : "");
    return sStatusB;
}

int Q2_VR_SenseAuthState(void)     { return sAuthState; }
int Q2_VR_SenseLoadFailCode(void)  { return sLoadFailCode; }
int Q2_VR_SenseAnchorCount(void)   { return sLastAnchorCount; }

// ---------------------------------------------------------------------------------------
// Synthetic injection
// ---------------------------------------------------------------------------------------
void Q2_VR_SenseSetSynthHand(int hand, int on, float yaw, float pitch, float roll,
                             float x, float y, float z)
{
    if (hand < 0 || hand > 1) return;
    sSynthOn[hand] = on ? 1 : 0;
    if (on) {
        sSynthPose[hand] = q2_synth_matrix(yaw, pitch, roll, x, y, z);
    } else {
        sSynthButtons[hand] = 0;
        sSynthStick[hand][0] = sSynthStick[hand][1] = 0.0f;
    }
}

void Q2_VR_SenseSetSynthButtons(int hand, unsigned buttons)
{
    if (hand >= 0 && hand <= 1) sSynthButtons[hand] = buttons;
}

void Q2_VR_SenseSetSynthStick(int hand, float x, float y)
{
    if (hand < 0 || hand > 1) return;
    sSynthStick[hand][0] = x;
    sSynthStick[hand][1] = y;
}

int Q2_VR_SenseSynthActive(void) { return sSynthOn[0] || sSynthOn[1]; }

// The doff fault injector. Drops BOTH hands the way a disconnect does — synthetic hands
// included — so "taking the controllers off releases everything exactly once" is a claim a
// simulator can prove rather than a comment.
void Q2_VR_SenseForceDoff(void)
{
    pthread_mutex_lock(&sLock);
    sHand[0] = sHand[1] = nil;
    for (int i = 0; i < 2; i++) {
        sEdgeUp[i] |= sEdgeLevel[i];    // the release travels the ordinary path
        sEdgeLevel[i] = 0;
        sEdgeDown[i] = 0;
    }
    sEdgeHands = 0;
    sEdgeStick[0] = sEdgeStick[1] = sEdgeStick[2] = sEdgeStick[3] = 0.0f;
    pthread_mutex_unlock(&sLock);
    for (int h = 0; h < 2; h++) {
        sSynthOn[h] = 0;
        sSynthButtons[h] = 0;
        sSynthStick[h][0] = sSynthStick[h][1] = 0.0f;
    }
    Q2_VR_Log("SENSE forced doff: both hands dropped (fault injector)");
}

#endif // Q2_XR_UI
