// q2repro iOS — app shell / entry (M2 + M5 touch input).
// Creates the CAEAGLLayer the native video driver renders into, boots the engine
// (Qcommon_Init), drives one Qcommon_Frame per CADisplayLink tick, and provides
// touch controls: left half = movement joystick, right half = look drag, plus
// FIRE / JUMP buttons.
#import <UIKit/UIKit.h>
#if !TARGET_OS_VISION
#import <QuartzCore/CAEAGLLayer.h>   // GLES layer: iOS/tvOS only (no GLES on visionOS)
#endif
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Haptics exist on iOS but not visionOS (no Taptic hardware in the headset). One
// macro keeps the call sites identical; it compiles to a no-op on visionOS.
#if TARGET_OS_VISION
#define Q2_HAPTIC(h)   do { } while (0)
#else
#define Q2_HAPTIC(h)   [(h) impactOccurred]
#endif

// Engine / driver C entry points (forward-declared to avoid engine-header macro
// collisions with Foundation/UIKit).
extern void Qcommon_Init(int argc, char **argv);
extern void Qcommon_Frame(void);
extern void VID_iOS_SetLayer(void *layer);
extern void VID_iOS_Resize(void);   // window resized (visionOS): rebuild the drawable at new size
extern void VID_iOS_RequestCapture(const char *path);
extern void VID_iOS_AddLook(float dx, float dy);
extern void VID_iOS_Command(const char *cmd);
extern void VID_iOS_AnalogMove(float forward, float side);   // analog move axis [-1,1], funnelled
extern void CL_Activate(int active);
#define ACT_MINIMIZED 0
#define ACT_ACTIVATED 2

// Menu (UI) bridge — ios_bridge.m.
extern bool VID_iOS_MenuActive(void);
extern void VID_iOS_MenuMouse(int px, int py);
extern void VID_iOS_MenuKey(int which, bool down);
extern void VID_iOS_ToggleMenu(void);
enum { IOS_MENU_CLICK = 0, IOS_MENU_UP, IOS_MENU_DOWN, IOS_MENU_LEFT,
       IOS_MENU_RIGHT, IOS_MENU_ENTER, IOS_MENU_BACK };
// Audio session policy + master mix gain — ios_audio.m.
extern void  Q2_iOS_AudioBoot(void);
extern void  Q2_iOS_AudioTick(void);
extern void  Q2_VR_Tick(void);        // q2_vr_dumps.m — black box flush (coalesced ~1 Hz)
extern void  Q2_VR_SetMode(int mode); // q2_vr_dumps.m — 0 = 2D window, 1 = 3D panel, 2 = VR
extern int   Q2_VR_Mode(void);
extern void  Q2_VR_Log(const char *msg);
// [R14b] The crash marker: armed while the app is in the FOREGROUND, cleared on a clean
// background. A marker still set at the next launch is the only trace a jetsam kill leaves.
extern void  Q2_VR_MarkRunning(int running);   // q2_vr_dumps.m
#if defined(Q2_XR_UI) && Q2_XR_UI
#include <stdatomic.h>
// q2_vr_input.m — the merged pad snapshot, and the crash-safe cvar stash.
extern void  Q2_VR_PadSticks(float lx, float ly, float rx, float ry, int injected);
extern void  Q2_VR_PadClear(void);
extern void  Q2_VR_PadClearPad(void);
extern void  Q2_VR_StashCvars(void);
extern void  Q2_VR_RestoreCvars(void);
extern void  Q2_VR_RepairLeftoverStash(void);
extern void  Q2_VR_RegisterInputCommands(void);
#if defined(Q2_XR_UI) && Q2_XR_UI
extern int   Q2_VR_SenseShouldIgnoreGamepad(const char *name);   // q2_vr_sense.m
extern int   Q2_VR_SenseOrdinaryPadCount(void);
extern void  Q2_VR_HandsUIFrame(void);                           // q2_vr_hands.m
#endif
extern void  VID_iOS_XR3_SetUIRedirect(int on);
#endif
// iOS settings cvars — ios_bridge.m.
extern void  VID_iOS_RegisterCvars(void);
extern float VID_iOS_SensX(void);
extern float VID_iOS_SensY(void);
extern bool  VID_iOS_InvertY(void);
extern float VID_iOS_TouchScale(void);
extern float VID_iOS_TouchAlpha(void);
extern bool  VID_iOS_TouchLefty(void);
extern bool  VID_iOS_Haptics(void);
extern int   VID_iOS_DisplayFps(void);
extern bool  VID_iOS_ShowFps(void);   // on-screen FPS counter toggle (ios_fps)
// Raw engine key events (route touch/pad buttons through the bind system).
extern void VID_iOS_KeyEvent(int keynum, bool down);
extern void VID_iOS_EnsureGamepadBinds(void);   // default pad layout for vanilla-pak installs
extern bool VID_iOS_KeyIsWaiting(void);
extern int  VID_iOS_PassiveState(void);   // 0 interactive, 1 demo, 2 cinematic
extern bool VID_iOS_Disconnected(void);   // no server/demo/cinematic → attract may start
extern void VID_iOS_SkipCinematic(void);
extern void VID_iOS_PadStartButton(void);   // [R7b] the ONE Start body
extern void Q2_iOS_MenuPauseTick(void);     // [R7b] menu-pause reconciliation
extern void VID_iOS_LookDelta(float yaw, float pitch);    // absolute degrees (touch/gyro)
extern void VID_iOS_LookAnalog(float yaw, float pitch);   // stick rate (pre-scaled)
#if defined(Q2_XR_UI) && Q2_XR_UI
// Merged 2D+3D (vid_angle.m stereo mode + client/screen.c). In 3D the tick renders the
// complete frame twice per engine step — left/right eye, same game time.
extern int  VID_iOS_XR3_Active(void);
extern void VID_iOS_XR3_SetMode(int on);
#include "immersive/q2_vr_glue.h"        // VR rendezvous, engine thread, depth handoff
extern void VID_iOS_XR3_BeginEye(int eye, float halfSep, float convergence);
extern void VID_iOS_XR3_EndFrame(void);
extern void SCR_UpdateScreen(void);
#endif
extern bool VID_iOS_IsAction(void);                       // classic Action Quake active (fs_game)
extern bool VID_iOS_LayoutActive(void);                   // game-drawn menu/layout up (Action join/loadout)
extern void VID_iOS_WheelCursor(float x, float y);        // touch wheel: absolute cursor (follows finger)
extern void VID_iOS_SetWheelAnchor(float ux, float uy);   // render the wheel centred at the button
#define LOOK_DEG_PER_PT 0.34   // touch degrees per point at neutral sensitivity (matched to controller)
static inline CGFloat lookAccel(CGFloat d) {   // velocity boost, capped 2.4x (Fable's curve)
    CGFloat boost = 1.0 + fabs(d) / 28.0;
    return d * (boost > 2.4 ? 2.4 : boost);
}
// KEX gamepad virtual keycodes (must match inc/client/keys.h) + K_ESCAPE.
enum { K_ESCAPE_ = 27,
       K_A_BUTTON = 214, K_B_BUTTON, K_X_BUTTON, K_Y_BUTTON,
       K_LEFT_SHOULDER, K_RIGHT_SHOULDER, K_LEFT_TRIGGER, K_RIGHT_TRIGGER,
       K_LEFT_STICK, K_RIGHT_STICK, K_START_BUTTON, K_BACK_BUTTON,
       K_DPAD_UP, K_DPAD_DOWN, K_DPAD_LEFT, K_DPAD_RIGHT };

static const CGFloat STICK_RADIUS = 70;   // visual joystick base radius

// ---- CAEAGLLayer-backed view + touch input ---------------------------------
@interface GLView : UIView
// Touch-layout editor entry points (also reached from ios_bridge.m via the C seams below).
- (void)ensureButtons;
- (void)ensureLayoutLoaded;
- (void)toggleEditing;
- (void)beginEditingLayout;
- (void)endEditingLayout;
- (void)resetLayoutToDefaults;
- (BOOL)isEditingLayout;
- (NSString *)layoutDescription;
- (BOOL)fakeTouchAt:(CGPoint)nrm phase:(int)phase;
@end

// ---- Touch layout persistence (NSUserDefaults, "q2." namespace) --------------
// Per-control positions live in NSUserDefaults (like the 3D panel settings), NOT
// engine cvars: the shell already reads/writes user defaults, and it avoids per-
// button cvar plumbing. The GLOBAL scale stays the existing ios_touch_scale cvar
// (read every frame by updateTouchUI), so the editor slider just writes that live.
// q2.layoutSet records whether the user has customised anything at all — while it
// is 0, new shipped defaults apply; once the user drags one control it flips to 1
// and every control reads its saved position (per-key default = its shipped one).
static float Q2Def_f(NSString *key, float def) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    return [d objectForKey:key] ? [d floatForKey:key] : def;
}
static void Q2Def_setf(NSString *key, float v) { [NSUserDefaults.standardUserDefaults setFloat:v forKey:key]; }
static NSString *Q2BtnKeyX(NSString *ident) { return [NSString stringWithFormat:@"q2.btn.%@.x", ident]; }
static NSString *Q2BtnKeyY(NSString *ident) { return [NSString stringWithFormat:@"q2.btn.%@.y", ident]; }
static NSString * const Q2LayoutSetKey = @"q2.layoutSet";

// The move stick is a ZONE, not a position: a draggable activation circle (ident
// "stick"), invisible in play (the stick floats to wherever the thumb lands) and
// drawn at its true radius in the editor so what you drag is exactly what responds.
static const CGFloat STICK_ZONE_DIAMETER = 300;

// In-game touch-control glyph metrics. Both are fractions of the button's LIVE
// diameter (base size × ios_touch_scale), so a glyph — and a text label on the
// handful of buttons that have no symbol — tracks the layout editor's size slider
// instead of sitting at a fixed point size inside a resized circle.
// 0.396 = the previous 0.44, 10% smaller (2026-07-31, matches vkQuake's density).
#define Q2_GLYPH_RATIO  0.396f
#define Q2_LABEL_RATIO  0.28f     // text buttons (WPN / OK / Z+ and symbol fallbacks)
#define Q2_GLYPH_WEIGHT UIImageSymbolWeightRegular

// Weak ref to the live touch view so the console seams (touchedit / q2_faketouch,
// registered engine-side in ios_bridge.m) reach the editor without a singleton.
static __weak GLView *g_touchView;

@implementation GLView {
    UITouch *_moveTouch, *_lookTouch;
    CGPoint _moveOrigin, _lookLast;
    UIView *_stickBase, *_stickKnob;   // visual floating joystick
    // Each entry: b (UIButton, absent for the zone), id (stable ident, = save key),
    // defx/defy (shipped default unit), ux/uy (effective unit), sz (base pt), + flags
    // act/actgame/noaction (context) and zone (the move-stick activation circle).
    NSMutableArray<NSMutableDictionary *> *_btns;
    UIButton *_backBtn;                // menu-only BACK (arrow)
    UIButton *_gearBtn;                // menu-only gear → native iOS settings panel
    UIButton *_qsaveBtn, *_qloadBtn;   // quick save / quick load (menu chrome, live SP game only)
    UIView *_touchCursor;             // menu-only "where you tapped" crosshair ring+dot
    UIButton *_wheelBtn;              // context button: wheel (Quake 2) / WPN (Action)
    int _wheelIsAction;               // -1 unknown; tracks _wheelBtn's current mode
    id _haptic;   // UIImpactFeedbackGenerator on iOS; nil on visionOS (no haptics)
    CGSize _lastDrawPx;   // last drawable pixel size, to fire VID_iOS_Resize only on real change
    // ---- touch layout editor ----
    BOOL _editing;                     // layout edit mode active
    BOOL _layoutLoaded;                // saved positions pulled into _btns once
    NSMutableDictionary *_dragBtn;     // control under the editing finger (nil = none)
    CGSize _dragOffset;                // finger→center delta, so a grab doesn't jump
    NSMutableDictionary *_stickZoneD;  // the move-zone entry in _btns (ident "stick")
    UIView *_stickZoneView;            // faint circle at the zone's true radius (editor only)
    UIView *_editBar;                  // editor chrome bar (reset · scale slider · done)
    UISlider *_editSlider; UILabel *_editPct;
}
+ (Class)layerClass {
#if defined(Q2_USE_ANGLE) && Q2_USE_ANGLE
    return [CAMetalLayer class];   // ANGLE renders to Metal via EGL window surface
#else
    return [CAEAGLLayer class];
#endif
}

// Follow window resizes (visionOS windows are user-resizable). When the drawable pixel
// size actually changes, rebuild the ANGLE surface so the render fills the whole window.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize px = CGSizeMake(self.bounds.size.width  * self.contentScaleFactor,
                           self.bounds.size.height * self.contentScaleFactor);
    if (px.width >= 1 && px.height >= 1 && !CGSizeEqualToSize(px, _lastDrawPx)) {
        _lastDrawPx = px;
        VID_iOS_Resize();   // no-op until the driver is initialized
    }
}

- (void)ensureStick {
    if (_stickBase) return;
    _stickBase = [[UIView alloc] initWithFrame:CGRectMake(0, 0, STICK_RADIUS*2, STICK_RADIUS*2)];
    _stickBase.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _stickBase.layer.cornerRadius = STICK_RADIUS;
    _stickBase.layer.borderWidth = 2; _stickBase.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _stickBase.userInteractionEnabled = NO; _stickBase.hidden = YES;
    _stickKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 56, 56)];
    _stickKnob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.28];
    _stickKnob.layer.cornerRadius = 28;
    _stickKnob.userInteractionEnabled = NO; _stickKnob.hidden = YES;
    [self addSubview:_stickBase]; [self addSubview:_stickKnob];
}
- (void)showStickAt:(CGPoint)p { [self ensureStick]; _stickBase.center = p; _stickKnob.center = p; _stickBase.hidden = _stickKnob.hidden = NO; }
- (void)moveKnob:(CGPoint)p {
    CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y;
    CGFloat d = hypot(dx, dy);
    if (d > STICK_RADIUS) { dx *= STICK_RADIUS/d; dy *= STICK_RADIUS/d; }
    _stickKnob.center = CGPointMake(_moveOrigin.x + dx, _moveOrigin.y + dy);
}
- (void)hideStick { _stickBase.hidden = _stickKnob.hidden = YES; }

- (void)ensureCursor {
    if (_touchCursor) return;
    // Quake II crosshair: four thin ticks around an OPEN center (not a solid +). Subtle,
    // semi-transparent white. Marks where the finger last touched — the touch menu's mouse.
    CGFloat sz = 34, t = 1.5, tick = 10, c = (sz - t) / 2;
    _touchCursor = [[UIView alloc] initWithFrame:CGRectMake(0, 0, sz, sz)];
    _touchCursor.userInteractionEnabled = NO; _touchCursor.hidden = YES;
    _touchCursor.alpha = 0.4;
    UIView *top = [[UIView alloc] initWithFrame:CGRectMake(c, 0, t, tick)];
    UIView *bot = [[UIView alloc] initWithFrame:CGRectMake(c, sz - tick, t, tick)];
    UIView *lft = [[UIView alloc] initWithFrame:CGRectMake(0, c, tick, t)];
    UIView *rgt = [[UIView alloc] initWithFrame:CGRectMake(sz - tick, c, tick, t)];
    for (UIView *v in @[top, bot, lft, rgt]) { v.backgroundColor = UIColor.whiteColor; [_touchCursor addSubview:v]; }
    [self addSubview:_touchCursor];
}
- (void)menuTouch:(UITouch *)t {   // drive the UI cursor from a touch (device pixels)
    CGPoint p = [t locationInView:self];
    CGFloat s = self.contentScaleFactor;
    VID_iOS_MenuMouse((int)(p.x * s), (int)(p.y * s));
    [self ensureCursor];
    _touchCursor.center = p;
    _touchCursor.hidden = NO;
    [self bringSubviewToFront:_touchCursor];
}

// While VR owns the presentation the game window is parked behind an opaque curtain and is
// not a gameplay surface. A touch that reached the funnel from there would inject a move or a
// key the player cannot see themselves making — and worse, a touch in flight when the space
// opened would never get its touchesEnded, so the latch would hold forever. Gamepad is the
// input story in VR; touch is not, and saying so once at the source beats gating six
// producers.
#if defined(Q2_XR_UI) && Q2_XR_UI
#define Q2_TOUCH_DEAD_IN_VR()  do { if (Q2_VR_Mode() == 2) return; } while (0)
#else
#define Q2_TOUCH_DEAD_IN_VR()  do { } while (0)
#endif

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    Q2_TOUCH_DEAD_IN_VR();
    if (_editing) { [self editDragBegin:[touches.anyObject locationInView:self]]; return; }
    // Attract sequence: tap skips the intro cinematic / opens the menu over the demo.
    int ps = VID_iOS_PassiveState();
    if (ps == 2) { VID_iOS_SkipCinematic(); return; }                       // tap skips the intro
    if (ps == 1 && !VID_iOS_MenuActive()) { VID_iOS_ToggleMenu(); return; } // tap over demo → menu

    if (VID_iOS_MenuActive()) {
        [self menuTouch:touches.anyObject];
        VID_iOS_MenuKey(IOS_MENU_CLICK, YES);
        return;
    }
    // Drop stale references first: a look/move touch that ended without us being told
    // (e.g. cancelled when a button/gesture claimed it) otherwise blocks its slot forever
    // — that's the "look drag stops working after I hit fire" bug.
    NSSet *active = e.allTouches;
    if (_lookTouch && ![active containsObject:_lookTouch]) _lookTouch = nil;
    if (_moveTouch && ![active containsObject:_moveTouch]) { _moveTouch = nil; VID_iOS_AnalogMove(0,0); [self hideStick]; }

#if defined(Q2_XR_UI) && Q2_XR_UI
    if (Q2_VR_SenseOrdinaryPadCount() > 0) return;    // ordinary pad only — a Sense half is not one
#else
    if (GCController.controllers.count > 0) return;   // gamepad connected → ignore touch move/look
#endif
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // The move stick is a ZONE, not the left half: a touch inside the (draggable) zone
        // circle floats the stick to the finger; anything else becomes the look drag.
        if ([self pointInMoveZone:p] && !_moveTouch) { _moveTouch = t; _moveOrigin = p; [self showStickAt:p]; }
        else if (!_lookTouch)                        { _lookTouch = t; _lookLast = p; }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    Q2_TOUCH_DEAD_IN_VR();
    if (_editing) { [self editDragMove:[touches.anyObject locationInView:self]]; return; }
    if (VID_iOS_MenuActive()) { [self menuTouch:touches.anyObject]; return; }
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // Re-acquire look if our reference was lost while the finger is still down (and it's
        // not in the move zone — that would be a move touch).
        if (t != _moveTouch && t != _lookTouch && !_lookTouch && ![self pointInMoveZone:p]) {
            _lookTouch = t; _lookLast = p;   // re-anchor; no delta this frame
        }
        if (t == _moveTouch) {
            CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y;
            CGFloat d = hypot(dx, dy);
            if (d > STICK_RADIUS) { dx *= STICK_RADIUS/d; dy *= STICK_RADIUS/d; }
            VID_iOS_AnalogMove((float)(-dy / STICK_RADIUS), (float)(dx / STICK_RADIUS));  // analog: up=forward
            [self moveKnob:p];
        } else if (t == _lookTouch) {
            // Direct-degree look (bypasses engine sensitivity/accel): ios_sens_* is the sole control.
            CGFloat sx = VID_iOS_SensX() / 3.0, sy = VID_iOS_SensY() / 3.0;   // neutral 3 = 1.0×
            CGFloat ax = lookAccel(p.x - _lookLast.x), ay = lookAccel(p.y - _lookLast.y);
            CGFloat iy = VID_iOS_InvertY() ? -1.0 : 1.0;
            VID_iOS_LookDelta((float)(-ax * LOOK_DEG_PER_PT * sx), (float)(iy * ay * LOOK_DEG_PER_PT * sy));
            _lookLast = p;
        }
    }
}

- (void)endTouches:(NSSet<UITouch *> *)touches {
    if (_editing) { [self editDragEnd]; return; }
    if (VID_iOS_MenuActive()) { VID_iOS_MenuKey(IOS_MENU_CLICK, NO); return; }
    for (UITouch *t in touches) {
        if (t == _moveTouch) {
            _moveTouch = nil;
            VID_iOS_AnalogMove(0, 0);
            [self hideStick];
        } else if (t == _lookTouch) {
            _lookTouch = nil;
        }
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { Q2_TOUCH_DEAD_IN_VR(); [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { Q2_TOUCH_DEAD_IN_VR(); [self endTouches:touches]; }

// ---- On-screen touch buttons (Fable-style unit-anchored layout) -------------
// Buttons send KEX virtual keys so they share binds with the controller. Hold
// buttons (WHL/JMP/FIRE/CRO) = key down/up; tap buttons (MENU/SCR/BACK) = command.
// label: a plain string → bold text; a string prefixed "sf:" → SF Symbol image (scaled
// to fill the round button). sym pt sizing is derived from the button size in layout.
- (UIButton *)makePad:(NSString *)label {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    if ([label hasPrefix:@"sf:"]) {
        // "sf:<symbol>[|<fallback text>]" — glyph on the button, with a word fallback
        // if systemImageNamed: returns nil, so an unknown symbol never ships a blank
        // circle (§8). scope/arrow.up/arrow.down are iOS 13+, so this is belt-and-braces.
        NSArray *parts = [[label substringFromIndex:3] componentsSeparatedByString:@"|"];
        UIImage *img = [UIImage systemImageNamed:parts.firstObject];
        if (img) {
            [b setImage:img forState:UIControlStateNormal];
            b.adjustsImageWhenHighlighted = NO;
        } else {
            [b setTitle:(parts.count > 1 ? parts[1] : parts.firstObject) forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        }
    } else {
        [b setTitle:label forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    }
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b.layer.borderWidth = 1.5; b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    [self addSubview:b];
    return b;
}
- (void)ensureButtons {
    if (_btns) return;
    _btns = [NSMutableArray array];
#if !TARGET_OS_VISION
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
#endif
    // Every control carries a stable IDENT — the NSUserDefaults save key. Renaming one
    // silently resets that control for existing users, so idents are frozen. defx/defy
    // are the shipped defaults (used for Reset + as each key's fallback); ux/uy are the
    // effective position (overwritten from saved layout in ensureLayoutLoaded).
    NSMutableDictionary* (^add)(UIButton *, NSString *, CGFloat, CGFloat, CGFloat) =
      ^NSMutableDictionary *(UIButton *b, NSString *ident, CGFloat ux, CGFloat uy, CGFloat sz) {
        NSMutableDictionary *d = [@{@"b":b, @"id":ident, @"defx":@(ux), @"defy":@(uy),
                                    @"ux":@(ux), @"uy":@(uy), @"sz":@(sz)} mutableCopy];
        [_btns addObject:d];
        return d;
    };
    // Hold button that sends a raw command on down/up (works in BOTH the rerelease AND the
    // classic Action game — unlike KEX virtual keys, which only resolve via rerelease binds,
    // so fire/jump/crouch were dead in Action).
    void (^cmdhold)(NSString *, NSString *, CGFloat, CGFloat, CGFloat, SEL, SEL) = ^(NSString *l, NSString *ident, CGFloat ux, CGFloat uy, CGFloat sz, SEL down, SEL up) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:down forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:up forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        add(b, ident, ux, uy, sz);
    };
    void (^tap)(NSString *, NSString *, CGFloat, CGFloat, CGFloat, SEL) = ^(NSString *l, NSString *ident, CGFloat ux, CGFloat uy, CGFloat sz, SEL s) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
        add(b, ident, ux, uy, sz);
    };
    // EXACT Fable layout (ios/shell/Q2TouchControls.m): unit fractions of the safe-area
    // rect, sizes in points. The top-right action button is context-sensitive: the weapon
    // WHEEL (hold) in Quake II, or WPN next-weapon (tap) in Action — set in updateTouchUI.
    _wheelBtn = [self makePad:@""];
    [_wheelBtn addTarget:self action:@selector(wheelDown:) forControlEvents:UIControlEventTouchDown];
    [_wheelBtn addTarget:self action:@selector(wheelDrag:forEvent:) forControlEvents:UIControlEventTouchDragInside|UIControlEventTouchDragOutside];
    [_wheelBtn addTarget:self action:@selector(wheelUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    _wheelIsAction = -1;
    add(_wheelBtn, @"wheel", 0.939, 0.304, 56);   // defaults promoted from a device-tuned layout (2026-07-29)
    // Item/powerup wheel (Quake II only), to the LEFT of the weapon wheel. Hold to open, drag to
    // select, release to pick — renders centred on this button (+wheel2 / -wheel2).
    UIButton *itemBtn = [self makePad:@"sf:bag.fill"];
    [itemBtn addTarget:self action:@selector(itemDown:) forControlEvents:UIControlEventTouchDown];
    [itemBtn addTarget:self action:@selector(wheelDrag:forEvent:) forControlEvents:UIControlEventTouchDragInside|UIControlEventTouchDragOutside];
    [itemBtn addTarget:self action:@selector(itemUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    add(itemBtn, @"item", 0.839, 0.308, 52)[@"noaction"] = @(1);
    // Action buttons carry GLYPHS with a word fallback (§8): fire=scope, jump=arrow.up, crouch=arrow.down.
    cmdhold(@"sf:arrow.up|JMP",    @"jump",   0.985, 0.503, 60, @selector(jumpDown), @selector(jumpUp));
    cmdhold(@"sf:scope|FIRE",      @"fire",   0.909, 0.719, 76, @selector(fireCmdDown), @selector(fireCmdUp));
    cmdhold(@"sf:arrow.down|CRO",  @"crouch", 0.986, 0.920, 52, @selector(crouchDown), @selector(crouchUp));
    tap(@"sf:line.3.horizontal", @"menu",   0.97,  0.09, 40, @selector(padMenu));     // menu (hamburger)
    tap(@"sf:list.number",       @"scores", 0.905, 0.09, 44, @selector(padScores));   // objectives / scoreboard

    // Action-only in-game menu nav (join team / loadout are game-drawn LAYOUT_MENU menus,
    // navigated by invprev/invnext/invuse — not clickable). Shown only while Action is active.
    void (^actbtn)(NSString *, NSString *, CGFloat, CGFloat, CGFloat, SEL) = ^(NSString *l, NSString *ident, CGFloat ux, CGFloat uy, CGFloat sz, SEL s) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
        add(b, ident, ux, uy, sz)[@"act"] = @(1);
    };
    actbtn(@"sf:chevron.up",   @"actprev", 0.055, 0.30, 44, @selector(actInvPrev));
    actbtn(@"sf:chevron.down", @"actnext", 0.055, 0.52, 44, @selector(actInvNext));
    actbtn(@"OK",              @"actuse",  0.055, 0.74, 44, @selector(actInvUse));
    // Action-only gameplay buttons ("actgame"): shown in Action when no game menu is up.
    // Top-left: (re)open the team/loadout menu. Right of FIRE: sniper zoom (cmd lens in cycles 1/2/4/6×).
    UIButton *recall = [self makePad:@"sf:person.2.fill"];
    [recall addTarget:self action:@selector(actMenuRecall) forControlEvents:UIControlEventTouchUpInside];
    add(recall, @"actmenu", 0.055, 0.09, 44)[@"actgame"] = @(1);
    UIButton *zoom = [self makePad:@"Z+"];
    [zoom addTarget:self action:@selector(actZoom) forControlEvents:UIControlEventTouchUpInside];
    add(zoom, @"actzoom", 0.985, 0.60, 52)[@"actgame"] = @(1);

    // Move-stick ZONE (ident "stick"): a draggable activation circle, not a button. It has no
    // UIButton, so it is naturally excluded from gameplay button hit-testing; the editor grabs
    // it and draws _stickZoneView at its true radius. Default centre reproduces the old left zone.
    _stickZoneView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, STICK_ZONE_DIAMETER, STICK_ZONE_DIAMETER)];
    _stickZoneView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    _stickZoneView.layer.cornerRadius = STICK_ZONE_DIAMETER / 2;
    _stickZoneView.layer.borderWidth = 2;
    _stickZoneView.layer.borderColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.5].CGColor;
    _stickZoneView.userInteractionEnabled = NO; _stickZoneView.hidden = YES;
    [self addSubview:_stickZoneView];
    _stickZoneD = [@{@"id":@"stick", @"zone":@(1), @"defx":@(0.162), @"defy":@(0.666),
                     @"ux":@(0.162), @"uy":@(0.666), @"sz":@(STICK_ZONE_DIAMETER)} mutableCopy];
    [_btns addObject:_stickZoneD];

    _backBtn = [self makePad:@"sf:arrowshape.turn.up.backward.fill"];   // menu-only back arrow
    [_backBtn addTarget:self action:@selector(padBack) forControlEvents:UIControlEventTouchUpInside];
    _backBtn.hidden = YES;
    _gearBtn = [self makePad:@"sf:gearshape.fill"];   // menu-only → native iOS settings panel
    [_gearBtn addTarget:self action:@selector(padSettings) forControlEvents:UIControlEventTouchUpInside];
    _gearBtn.hidden = YES;
    // Quick save / load — menu chrome (NOT part of the customizable layout), shown only while a
    // live single-player game is paused in a menu. Under the back/gear row, on the left.
    _qsaveBtn = [self makePad:@"SAVE"];
    [_qsaveBtn addTarget:self action:@selector(padQuickSave) forControlEvents:UIControlEventTouchUpInside];
    _qsaveBtn.hidden = YES;
    _qloadBtn = [self makePad:@"LOAD"];
    [_qloadBtn addTarget:self action:@selector(padQuickLoad) forControlEvents:UIControlEventTouchUpInside];
    _qloadBtn.hidden = YES;

    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerBack:)];
    g.numberOfTouchesRequired = 2; g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
}
// ==================== Customizable touch layout (editor) =====================
// Model: each control has an ident; positions persist to NSUserDefaults (q2.btn.<id>.x/y)
// gated by q2.layoutSet; the global scale is the ios_touch_scale cvar. The move stick is a
// draggable ZONE (ident "stick"), lefty is gone (migrated once). Console seams: touchedit /
// touchedit reset|print / q2_faketouch drive the SAME editDrag* methods a real finger does.

// Pull saved positions into _btns once (and migrate legacy lefty users on the way).
- (void)ensureLayoutLoaded {
    if (_layoutLoaded) return;
    _layoutLoaded = YES;
    // One-time migration for anyone who had the old "lefty touch layout" cvar on. That toggle
    // is gone — the editor plus the draggable move zone replace it — so bake the mirror it used
    // to apply at layout time into saved positions (buttons AND the stick zone, both in _btns)
    // so their whole scheme doesn't jump across the screen on update. Guarded by layoutSet<0.5
    // so it never clobbers someone who has already arranged their own layout.
    if (VID_iOS_TouchLefty() && Q2Def_f(Q2LayoutSetKey, 0.0f) < 0.5f) {
        for (NSMutableDictionary *d in _btns) {
            Q2Def_setf(Q2BtnKeyX(d[@"id"]), 1.0f - [d[@"defx"] doubleValue]);
            Q2Def_setf(Q2BtnKeyY(d[@"id"]), [d[@"defy"] doubleValue]);
        }
        Q2Def_setf(Q2LayoutSetKey, 1.0f);
        NSLog(@"[q2repro] migrated legacy lefty layout into a saved custom layout");
    }
    [self loadLayoutPositions];
}
// Effective position for every control: the saved one if the layout is customised, else its
// shipped default. Per-key default is still defx/defy, so a control that was never individually
// dragged lands on its default even in custom mode (two-level fallback, deliberate).
- (void)loadLayoutPositions {
    BOOL custom = Q2Def_f(Q2LayoutSetKey, 0.0f) > 0.5f;
    for (NSMutableDictionary *d in _btns) {
        if (custom) {
            d[@"ux"] = @(Q2Def_f(Q2BtnKeyX(d[@"id"]), [d[@"defx"] doubleValue]));
            d[@"uy"] = @(Q2Def_f(Q2BtnKeyY(d[@"id"]), [d[@"defy"] doubleValue]));
        } else {
            d[@"ux"] = d[@"defx"]; d[@"uy"] = d[@"defy"];
        }
    }
}
- (void)resetLayoutToDefaults {
    [self ensureButtons];   // "touchedit reset" can arrive before the first frame built them
    Q2Def_setf(Q2LayoutSetKey, 0.0f);
    for (NSMutableDictionary *d in _btns) {
        Q2Def_setf(Q2BtnKeyX(d[@"id"]), [d[@"defx"] doubleValue]);
        Q2Def_setf(Q2BtnKeyY(d[@"id"]), [d[@"defy"] doubleValue]);
    }
    VID_iOS_Command("set ios_touch_scale 1.0");   // the scale is part of the layout now
    [self loadLayoutPositions];
}

// Which controls are relevant to the current game context (ignores menu/pad/passive — the
// editor forces them visible). Same rules as updateTouchUI's per-frame hide logic.
- (BOOL)controlShownInContext:(NSDictionary *)d isAction:(BOOL)isAct layoutUp:(BOOL)layoutUp {
    if ([d[@"zone"] boolValue])     return YES;                 // move zone: editable (drawn only while editing)
    if ([d[@"actgame"] boolValue])  return isAct && !layoutUp;
    if ([d[@"noaction"] boolValue]) return !isAct;
    if ([d[@"act"] boolValue])      return isAct && layoutUp;
    return YES;                                                 // core controls
}
- (UIView *)viewFor:(NSDictionary *)d { return [d[@"zone"] boolValue] ? _stickZoneView : d[@"b"]; }
- (CGPoint)centerOf:(NSDictionary *)d {
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    return CGPointMake(r.origin.x + [d[@"ux"] doubleValue] * r.size.width,
                       r.origin.y + [d[@"uy"] doubleValue] * r.size.height);
}
// Grab the SMALLEST control under the finger, so a small button inside the big stick circle
// stays grabbable. Only controls relevant to the current context are grabbable.
- (NSMutableDictionary *)placeableAt:(CGPoint)p {
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (r.size.width <= 0 || r.size.height <= 0) return nil;
    CGFloat scale = VID_iOS_TouchScale();
    int isAct = VID_iOS_IsAction() ? 1 : 0; BOOL layoutUp = VID_iOS_LayoutActive();
    NSMutableDictionary *best = nil; CGFloat bestSz = 1e9;
    for (NSMutableDictionary *d in _btns) {
        if (![self controlShownInContext:d isAction:isAct layoutUp:layoutUp]) continue;
        CGFloat sz = [d[@"sz"] doubleValue] * scale;
        CGFloat cx = r.origin.x + [d[@"ux"] doubleValue] * r.size.width;
        CGFloat cy = r.origin.y + [d[@"uy"] doubleValue] * r.size.height;
        CGFloat hit = sz * 0.5 * ([d[@"zone"] boolValue] ? 1.0 : 1.3);   // zone = true radius; buttons generous
        CGFloat dx = p.x - cx, dy = p.y - cy;
        if (dx * dx + dy * dy <= hit * hit && sz < bestSz) { best = d; bestSz = sz; }
    }
    return best;
}
// Gameplay move-zone hit test (the single source of truth for "this touch starts movement").
- (BOOL)pointInMoveZone:(CGPoint)p {
    if (!_stickZoneD) return p.x < self.bounds.size.width * 0.5;   // pre-build fallback = old left half
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat cx = r.origin.x + [_stickZoneD[@"ux"] doubleValue] * r.size.width;
    CGFloat cy = r.origin.y + [_stickZoneD[@"uy"] doubleValue] * r.size.height;
    CGFloat rad = [_stickZoneD[@"sz"] doubleValue] * 0.5 * VID_iOS_TouchScale();
    CGFloat dx = p.x - cx, dy = p.y - cy;
    return dx * dx + dy * dy <= rad * rad;
}

// ---- Drag (real finger AND synthetic finger call these) ----
- (BOOL)editDragBegin:(CGPoint)p {
    _dragBtn = [self placeableAt:p];
    if (!_dragBtn) return NO;
    CGPoint c = [self centerOf:_dragBtn];
    _dragOffset = CGSizeMake(c.x - p.x, c.y - p.y);   // so the control doesn't jump to the fingertip
    UIView *v = [self viewFor:_dragBtn];
    v.backgroundColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.45];
    return YES;
}
- (void)editDragMove:(CGPoint)p {
    if (!_dragBtn) return;
    // Only constraint: the CENTRE stays on screen so anything placed can be grabbed again.
    // Deliberately NOT the safe rect and NOT inset by the radius (that refused positions the
    // controls ship at — jump defaults near x 0.99). Overshoot is cheap; Reset is right there.
    CGFloat cx = fmax(0, fmin(self.bounds.size.width,  p.x + _dragOffset.width));
    CGFloat cy = fmax(0, fmin(self.bounds.size.height, p.y + _dragOffset.height));
    [self viewFor:_dragBtn].center = CGPointMake(cx, cy);
}
- (void)editDragEnd {
    if (!_dragBtn) return;
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    UIView *v = [self viewFor:_dragBtn];
    if (v && r.size.width > 0 && r.size.height > 0) {
        // Normalize the raw-bounds center against the SAFE-AREA rect — asymmetric with the
        // clamp above ON PURPOSE, so edge controls keep their >1 / <0 shipped unit positions.
        CGFloat ux = (v.center.x - r.origin.x) / r.size.width;
        CGFloat uy = (v.center.y - r.origin.y) / r.size.height;
        _dragBtn[@"ux"] = @(ux); _dragBtn[@"uy"] = @(uy);
        Q2Def_setf(Q2BtnKeyX(_dragBtn[@"id"]), ux);
        Q2Def_setf(Q2BtnKeyY(_dragBtn[@"id"]), uy);
        Q2Def_setf(Q2LayoutSetKey, 1.0f);
        NSLog(@"[q2repro] layout: %@ -> (%.3f, %.3f)", _dragBtn[@"id"], ux, uy);
    }
    v.backgroundColor = [_dragBtn[@"zone"] boolValue] ? [UIColor colorWithWhite:1 alpha:0.05]
                                                      : [UIColor colorWithWhite:1 alpha:0.14];
    _dragBtn = nil;
}

// Release every in-flight input so entering edit mode never leaves a key/button asserted.
- (void)releaseAllInput {
    _moveTouch = nil; _lookTouch = nil;
    VID_iOS_AnalogMove(0, 0);
    [self hideStick];
    VID_iOS_Command("-attack"); VID_iOS_Command("-moveup"); VID_iOS_Command("-movedown");
    VID_iOS_Command("-wheel2");
    VID_iOS_KeyEvent(K_RIGHT_SHOULDER, NO);   // weapon wheel (+wheel) off
    VID_iOS_LookAnalog(0, 0);
}

- (BOOL)isEditingLayout { return _editing; }
- (void)toggleEditing { if (_editing) [self endEditingLayout]; else [self beginEditingLayout]; }
- (void)beginEditingLayout {
    if (_editing) return;
    [self ensureButtons];
    [self ensureLayoutLoaded];
    _editing = YES;
    [self releaseAllInput];
    VID_iOS_Command("forcemenuoff");   // judge placement against the game, not a menu backdrop
    for (NSMutableDictionary *d in _btns) {
        UIButton *b = d[@"b"];
        if (!b) continue;
        b.userInteractionEnabled = NO;   // route drags to GLView.touchesBegan, not the button's action
        b.layer.borderColor = [UIColor colorWithRed:1 green:0.85 blue:0.4 alpha:0.95].CGColor;
    }
    [self buildEditChrome];
    NSLog(@"[q2repro] touch layout editor entered");
}
- (void)endEditingLayout {
    if (!_editing) return;
    [self editDragEnd];   // commit anything still under the finger
    _editing = NO;
    for (NSMutableDictionary *d in _btns) {
        UIButton *b = d[@"b"];
        if (!b) continue;
        b.userInteractionEnabled = YES;
        b.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.22].CGColor;
    }
    _stickZoneView.hidden = YES;
    [_editBar removeFromSuperview]; _editBar = nil; _editSlider = nil; _editPct = nil;
    NSLog(@"[q2repro] touch layout editor exited");
}

// Chrome: reset · live scale slider (% above) · done — bottom-left, 42pt, Shipwright's layout.
// No instruction text: once you are here, dragging a button is self-evident.
- (void)buildEditChrome {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:bar]; _editBar = bar;

    UIButton *reset = [UIButton buttonWithType:UIButtonTypeSystem];
    reset.backgroundColor = [UIColor colorWithRed:0.85 green:0.20 blue:0.22 alpha:0.95];
    [reset setImage:[[UIImage systemImageNamed:@"arrow.uturn.backward"] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    reset.tintColor = UIColor.whiteColor; reset.layer.cornerRadius = 21;
    [reset addTarget:self action:@selector(editResetTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.backgroundColor = [UIColor colorWithRed:0.18 green:0.78 blue:0.34 alpha:0.95];
    [done setImage:[[UIImage systemImageNamed:@"checkmark"] imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightBold]] forState:UIControlStateNormal];
    done.tintColor = UIColor.whiteColor; done.layer.cornerRadius = 21;
    [done addTarget:self action:@selector(endEditingLayout) forControlEvents:UIControlEventTouchUpInside];

    UISlider *sl = [UISlider new];
    sl.minimumValue = 0.6f; sl.maximumValue = 1.6f;
    sl.value = VID_iOS_TouchScale();
    sl.minimumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [sl addTarget:self action:@selector(editScaleChanged:) forControlEvents:UIControlEventValueChanged];
    _editSlider = sl;

    UILabel *pct = [UILabel new];
    pct.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    pct.textColor = [UIColor colorWithWhite:1 alpha:0.9]; pct.textAlignment = NSTextAlignmentCenter;
    _editPct = pct; [self updateScaleLabel];

    for (UIView *v in @[reset, done, sl, pct]) { v.translatesAutoresizingMaskIntoConstraints = NO; [bar addSubview:v]; }
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.leadingAnchor constant:14],
        [bar.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-14],
        [bar.heightAnchor constraintEqualToConstant:42],
        [bar.trailingAnchor constraintEqualToAnchor:done.trailingAnchor],
        [reset.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [reset.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [reset.widthAnchor constraintEqualToConstant:42], [reset.heightAnchor constraintEqualToConstant:42],
        [sl.leadingAnchor constraintEqualToAnchor:reset.trailingAnchor constant:16],
        [sl.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [sl.widthAnchor constraintEqualToConstant:220],
        [pct.centerXAnchor constraintEqualToAnchor:sl.centerXAnchor],
        [pct.bottomAnchor constraintEqualToAnchor:sl.topAnchor constant:-2],
        [done.leadingAnchor constraintEqualToAnchor:sl.trailingAnchor constant:16],
        [done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [done.widthAnchor constraintEqualToConstant:42], [done.heightAnchor constraintEqualToConstant:42],
    ]];
}
- (void)updateScaleLabel { _editPct.text = [NSString stringWithFormat:@"%.0f%%", VID_iOS_TouchScale() * 100.0f]; }
- (void)editScaleChanged:(UISlider *)s {
    // Write the same cvar updateTouchUI reads every frame, so buttons AND the zone resize live.
    VID_iOS_Command([NSString stringWithFormat:@"set ios_touch_scale %.3f", s.value].UTF8String);
    [self updateScaleLabel];
}
- (void)editResetTapped {
    [self resetLayoutToDefaults];
    _editSlider.value = VID_iOS_TouchScale();   // reset put it back to 1.0
    [self updateScaleLabel];
    NSLog(@"[q2repro] touch layout reset to defaults");
}

// ---- Console seams (called from ios_bridge.m command handlers on the main thread) ----
// Dump the live layout in the exact form the defaults table takes, so a layout arranged on the
// device can be read back and promoted to shipped defaults without transcribing by eye.
- (NSString *)layoutDescription {
    [self ensureButtons];        // `touchedit print` can arrive before the editor/first frame built them
    [self ensureLayoutLoaded];   // reflect the persisted layout, not creation-time defaults
    NSMutableString *s = [NSMutableString stringWithFormat:@"touch layout - scale %.2f, customised=%@\n",
                          VID_iOS_TouchScale(), Q2Def_f(Q2LayoutSetKey, 0.0f) > 0.5f ? @"yes" : @"no (defaults)"];
    for (NSMutableDictionary *d in _btns)
        [s appendFormat:@"  %-8s size %3.0f  at CGPointMake(%.3f, %.3f)\n",
             [d[@"id"] UTF8String], [d[@"sz"] doubleValue], [d[@"ux"] doubleValue], [d[@"uy"] doubleValue]];
    return s;
}
// Synthetic finger: injected UIKit touches never reach the touch path on the sim, so this drives
// the SAME editDrag* methods a real finger does. phase 0 down / 1 move / 2 up / 3 zone-query.
- (BOOL)fakeTouchAt:(CGPoint)nrm phase:(int)phase {
    // Map against the SAFE-AREA rect so faketouch coords match the layout's unit space (the same
    // fractions `touchedit print` reports) — a control is grabbable at exactly its printed x,y.
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGPoint p = CGPointMake(r.origin.x + nrm.x * r.size.width, r.origin.y + nrm.y * r.size.height);
    if (phase == 3) {   // pure query — the only part of an invisible zone a screenshot can't prove
        BOOL in = [self pointInMoveZone:p];
        NSLog(@"[q2repro] movezone (%.0f,%.0f) -> %@", p.x, p.y, in ? @"INSIDE" : @"outside");
        return in;
    }
    if (!_editing) { NSLog(@"[q2repro] q2_faketouch ignored — layout editor is not open"); return NO; }
    switch (phase) {
        case 0: { BOOL g = [self editDragBegin:p]; NSLog(@"[q2repro] faketouch down (%.0f,%.0f) grabbed=%d", p.x, p.y, g); return g; }
        case 1: [self editDragMove:p]; return YES;
        default: [self editDragEnd]; return YES;
    }
}

// Scale an SF-Symbol button's glyph to fill its round frame.
- (void)sizeSymbol:(UIButton *)b to:(CGFloat)sz ratio:(CGFloat)ratio weight:(UIImageSymbolWeight)w {
    if (!b.currentImage) return;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:sz*ratio weight:w];
    [b setPreferredSymbolConfiguration:cfg forImageInState:UIControlStateNormal];
}
// A gameplay button's contents (SF Symbol OR text label) sized from its LIVE diameter,
// so both follow the layout editor's size slider. Re-rendering the symbol at the new
// point size — rather than stretching a fixed-size image — keeps it vector-crisp at
// every scale; the cached "glyphsz" keeps that off the per-frame path (updateTouchUI runs
// every display-link tick, and only the slider ever changes this).
- (void)sizePadContents:(NSMutableDictionary *)d to:(CGFloat)sz {
    if (fabs([d[@"glyphsz"] doubleValue] - sz) < 0.01) return;
    d[@"glyphsz"] = @(sz);
    UIButton *b = d[@"b"];
    [self sizeSymbol:b to:sz ratio:Q2_GLYPH_RATIO weight:Q2_GLYPH_WEIGHT];
    if (b.currentTitle.length)
        b.titleLabel.font = [UIFont boldSystemFontOfSize:sz * Q2_LABEL_RATIO];
}
- (void)padDown:(UIButton *)b {
    VID_iOS_KeyEvent((int)b.tag, YES);
    if (b.tag == K_RIGHT_TRIGGER && VID_iOS_Haptics()) Q2_HAPTIC(_haptic);
}
- (void)padUp:(UIButton *)b { VID_iOS_KeyEvent((int)b.tag, NO); }
- (void)padMenu   { VID_iOS_ToggleMenu(); }
- (void)padSettings { VID_iOS_Command("ios_settings"); }   // native iOS settings panel
- (void)padScores { VID_iOS_Command("cmd help"); }   // help computer / objectives (the numbered list)
// Quick save: the menu's own save path is `save <slot>; forcemenuoff`, so replicate it (a raw
// `save` would leave the menu sitting over the game). Quick load: a bare `load` — the reconnect
// takes the menu down on its own (mirrors the engine Load menu, which issues no forcemenuoff).
- (void)padQuickSave { VID_iOS_Command("save quick"); VID_iOS_Command("forcemenuoff"); if (VID_iOS_Haptics()) Q2_HAPTIC(_haptic); }
- (void)padQuickLoad { if ([self quickSaveExists]) VID_iOS_Command("load quick"); }
// Chrome visibility: a live, interactive (non-demo/cinematic) session with a menu up. Save is
// allowed in SP + coop and no-ops in deathmatch, so this deliberately does not gate on player count.
- (BOOL)quickChromeAvailable { return VID_iOS_MenuActive() && !VID_iOS_Disconnected() && VID_iOS_PassiveState() == 0; }
// Does a quicksave exist? Q2 saves are directories under <homedir>/baseq2/save/<name>/; server.ssv
// is the marker. homedir is the profile dir (rerelease/original) — stat it live, no engine call.
- (BOOL)quickSaveExists {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *p = [docs stringByAppendingPathComponent:@"profile/baseq2/save/quick/server.ssv"];
    return [NSFileManager.defaultManager fileExistsAtPath:p];
}
// Render the open wheel centred on the button that opened it (HUD-fraction anchor), so the
// cursor's origin is the button. -1,-1 restores the default (right/left-of-centre) placement.
- (void)setWheelAnchorForButton:(UIButton *)b {
    VID_iOS_SetWheelAnchor((float)(b.center.x / self.bounds.size.width),
                           (float)(b.center.y / self.bounds.size.height));
}
// Weapon-wheel button: Quake II → hold to open the weapon wheel (release selects); Action → tap = next weapon.
- (void)wheelDown:(UIButton *)b {
    if (VID_iOS_IsAction()) { VID_iOS_Command("weapnext"); return; }
    [self setWheelAnchorForButton:b];
    VID_iOS_KeyEvent(K_RIGHT_SHOULDER, YES);     // +wheel (rerelease bind)
}
// Item/powerup-wheel button (Quake II only): hold to open (+wheel2), drag to select, release picks.
- (void)itemDown:(UIButton *)b {
    if (VID_iOS_IsAction()) return;
    [self setWheelAnchorForButton:b];
    VID_iOS_Command("+wheel2");
}
- (void)itemUp:(UIButton *)b {
    if (!VID_iOS_IsAction()) { VID_iOS_LookAnalog(0, 0); VID_iOS_Command("-wheel2"); }
}
// While the wheel is held, dragging the finger picks by DIRECTION from screen center (where
// the wheel is drawn) — slide toward a weapon to select it, GTA-style. Fed through the same
// LookAnalog path the controller stick uses (CL_AdjustAngles WHEEL_OPEN branch slams the cursor).
// Touch wheel: the on-screen cursor follows the finger. Feed the finger's offset from screen
// centre (in device px) as an ABSOLUTE cursor position — engine clamps it to the wheel radius.
- (void)wheelDrag:(UIButton *)b forEvent:(UIEvent *)e {
    if (VID_iOS_IsAction()) return;
    UITouch *t = e.allTouches.anyObject;
    CGPoint p = [t locationInView:self];
    CGFloat s = self.contentScaleFactor;   // points → device px (the wheel's position space)
    // Offset from the WHEEL BUTTON centre (where the finger starts the drag): touch the button
    // → cursor at the wheel centre, then it tracks the drag from there. (Better than measuring
    // from screen centre, which slammed the cursor to the rim on first touch.)
    CGFloat dx = (p.x - b.center.x) * s;
    CGFloat dy = (p.y - b.center.y) * s;
    VID_iOS_WheelCursor((float)dx, (float)dy);
}
- (void)wheelUp:(UIButton *)b {
    if (!VID_iOS_IsAction()) { VID_iOS_LookAnalog(0, 0); VID_iOS_KeyEvent(K_RIGHT_SHOULDER, NO); }
}
- (void)actInvPrev { VID_iOS_Command("invprev"); }   // AQ2 menu: cursor up
- (void)actInvNext { VID_iOS_Command("invnext"); }   // AQ2 menu: cursor down
- (void)actInvUse  { VID_iOS_Command("invuse"); }    // AQ2 menu: select highlighted
- (void)actMenuRecall { VID_iOS_Command("cmd menu"); }  // (re)open the AQ2 team/loadout menu
- (void)actZoom { VID_iOS_Command("cmd lens"); }        // AQ2 sniper zoom — no-arg cycles 1→2→4→6→1×
// Fire/jump/crouch as raw commands so they work in Quake II AND classic Action.
- (void)fireCmdDown { VID_iOS_Command("+attack"); if (VID_iOS_Haptics()) Q2_HAPTIC(_haptic); }
- (void)fireCmdUp   { VID_iOS_Command("-attack"); }
- (void)jumpDown    { VID_iOS_Command("+moveup"); }
- (void)jumpUp      { VID_iOS_Command("-moveup"); }
- (void)crouchDown  { VID_iOS_Command("+movedown"); }
- (void)crouchUp    { VID_iOS_Command("-movedown"); }
- (void)padBack   { VID_iOS_MenuKey(IOS_MENU_BACK, YES); VID_iOS_MenuKey(IOS_MENU_BACK, NO); }
- (void)twoFingerBack:(UITapGestureRecognizer *)g {
    if (VID_iOS_MenuActive()) { VID_iOS_MenuKey(IOS_MENU_BACK, YES); VID_iOS_MenuKey(IOS_MENU_BACK, NO); }
}

// Called each frame: position + scale/opacity + hide when a menu is up. The editor rides on
// top of this loop — while editing, hideGame is forced off (controls stay visible even over a
// menu), the control under the finger keeps the position editDragMove gave it, and the move
// ZONE is drawn at its true radius; scale comes from the same ios_touch_scale cvar the slider
// writes, so resizing is live.
- (void)updateTouchUI {
    [self ensureButtons];
    [self ensureLayoutLoaded];
    BOOL editing = _editing;
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat scale = VID_iOS_TouchScale(), alpha = VID_iOS_TouchAlpha();
    BOOL inMenu = VID_iOS_MenuActive();
    BOOL passive = VID_iOS_PassiveState() != 0;         // demo / cinematic playing
#if defined(Q2_XR_UI) && Q2_XR_UI
    // Ordinary pads only: a Sense half enumerates as a gamepad once the declaration is in
    // place, and counting it here would hide the touch controls the moment a controller was
    // switched on in the 2D window.
    BOOL pad = Q2_VR_SenseOrdinaryPadCount() > 0;
#else
    BOOL pad = GCController.controllers.count > 0;      // a gamepad is connected
#endif
    BOOL hideGame = (inMenu || passive || pad) && !editing;   // controls only during live touch play (editor overrides)
    if (pad) VID_iOS_SetWheelAnchor(-1, -1);            // controller → wheel renders at default centre
    BOOL layoutUp = VID_iOS_LayoutActive();             // Action join/loadout menu on screen
    // Context button: weapon-wheel glyph in Quake II, "WPN" text in Action. Only reskin
    // on a game change (avoids per-frame churn). The wheel uses the FILLED hexagon grid —
    // the hollow variant read as a cluster of empty rings and did not match vkQuake's.
    int isAct = VID_iOS_IsAction() ? 1 : 0;
    if (isAct != _wheelIsAction) {
        _wheelIsAction = isAct;
        if (isAct) {
            [_wheelBtn setImage:nil forState:UIControlStateNormal];
            [_wheelBtn setTitle:@"WPN" forState:UIControlStateNormal];
        } else {
            [_wheelBtn setTitle:nil forState:UIControlStateNormal];
            [_wheelBtn setImage:[UIImage systemImageNamed:@"circle.hexagongrid.fill"] forState:UIControlStateNormal];
        }
        for (NSMutableDictionary *d in _btns)      // force a re-size of the swapped contents
            if (d[@"b"] == _wheelBtn) d[@"glyphsz"] = @(0);
    }
    for (NSMutableDictionary *d in _btns) {
        if ([d[@"zone"] boolValue]) continue;           // the move zone has no UIButton (drawn below)
        UIButton *b = d[@"b"];
        CGFloat sz = [d[@"sz"] doubleValue] * scale;
        // The control under the editing finger keeps the position editDragMove gave it.
        if (!(editing && d == _dragBtn)) {
            b.bounds = CGRectMake(0, 0, sz, sz);
            b.center = CGPointMake(r.origin.x + [d[@"ux"] doubleValue] * r.size.width,
                                   r.origin.y + [d[@"uy"] doubleValue] * r.size.height);
            b.layer.cornerRadius = sz / 2;
        }
        [self sizePadContents:d to:sz];   // glyph AND text label track ios_touch_scale
        b.alpha = editing ? 0.95 : alpha * 0.85;
        b.hidden = ![self controlShownInContext:d isAction:isAct layoutUp:layoutUp] || (hideGame && !editing);
    }
    // Move-stick zone: faint circle at true radius while editing, invisible in play.
    if (editing) {
        if (_stickZoneD != _dragBtn) {
            CGFloat zsz = [_stickZoneD[@"sz"] doubleValue] * scale;
            _stickZoneView.bounds = CGRectMake(0, 0, zsz, zsz);
            _stickZoneView.layer.cornerRadius = zsz / 2;
            _stickZoneView.center = CGPointMake(r.origin.x + [_stickZoneD[@"ux"] doubleValue] * r.size.width,
                                                r.origin.y + [_stickZoneD[@"uy"] doubleValue] * r.size.height);
        }
        _stickZoneView.hidden = NO;
        [self sendSubviewToBack:_stickZoneView];        // never cover a button you want to grab
        [self bringSubviewToFront:_editBar];            // chrome always on top
    } else {
        _stickZoneView.hidden = YES;
    }
    // The move-stick GRAPHIC is shown ONLY in the layout editor, parked in the middle of its zone
    // circle so it's clear the circle IS the move stick. In play it stays invisible until you
    // touch — then it floats to your thumb (touchesMoved owns it).
    if (editing) {
        [self ensureStick];
        _stickBase.center = _stickKnob.center = _stickZoneView.center;   // dead-centre the zone circle
        _stickBase.hidden = _stickKnob.hidden = NO;
    } else if (hideGame || !_moveTouch) {
        [self hideStick];
    }
    CGFloat bsz = 46 * scale;                           // smaller back button
    _backBtn.bounds = CGRectMake(0, 0, bsz, bsz);
    _backBtn.center = CGPointMake(r.origin.x + bsz*0.65, r.origin.y + bsz*0.65);
    _backBtn.layer.cornerRadius = bsz / 2;
    [self sizeSymbol:_backBtn to:bsz ratio:0.4 weight:UIImageSymbolWeightRegular];   // lighter/smaller arrow
    _backBtn.alpha = alpha * 0.9;
    _backBtn.hidden = !inMenu || editing;               // no stray back arrow in the editor
    // Gear → native iOS settings, just right of the back arrow (menu chrome, like back).
    _gearBtn.bounds = CGRectMake(0, 0, bsz, bsz);
    _gearBtn.center = CGPointMake(_backBtn.center.x + bsz*1.15, _backBtn.center.y);
    _gearBtn.layer.cornerRadius = bsz / 2;
    [self sizeSymbol:_gearBtn to:bsz ratio:0.42 weight:UIImageSymbolWeightRegular];
    _gearBtn.alpha = alpha * 0.9;
    _gearBtn.hidden = !inMenu || editing;
    // Quick save / load — under the back/gear row, only while a live SP/coop game is paused in a
    // menu. LOAD is a dead, dimmed button when no quicksave exists yet (the exists stat runs only
    // while these are eligible, i.e. paused in a menu — never during gameplay frames).
    BOOL qavail = [self quickChromeAvailable] && !editing;
    CGFloat qsz = 48 * scale, qy = _backBtn.center.y + bsz*1.2;
    _qsaveBtn.bounds = _qloadBtn.bounds = CGRectMake(0, 0, qsz, qsz);
    _qsaveBtn.center = CGPointMake(_backBtn.center.x, qy);
    _qloadBtn.center = CGPointMake(_gearBtn.center.x, qy);
    _qsaveBtn.layer.cornerRadius = _qloadBtn.layer.cornerRadius = qsz / 2;
    _qsaveBtn.alpha = alpha * 0.9;
    _qsaveBtn.hidden = _qloadBtn.hidden = !qavail;
    if (qavail) {
        BOOL exists = [self quickSaveExists];
        _qloadBtn.enabled = exists;
        _qloadBtn.alpha = alpha * (exists ? 0.9 : 0.35);   // dimmed + dead when no quicksave yet
    }
    if ((!inMenu || editing) && _touchCursor) _touchCursor.hidden = YES;   // cursor is menu-only
}
@end

// ---- Touch layout console seams (C ABI; handlers in ios_bridge.m call these) --
// All run on the main thread: iOS console commands execute inside Qcommon_Frame (the display
// link tick), the same thread UIKit lives on — so no locking is needed to touch views here.
void Q2_iOS_ToggleLayoutEdit(void) { [g_touchView toggleEditing]; }
void Q2_iOS_ResetLayout(void)      { [g_touchView resetLayoutToDefaults]; }   // "touchedit reset" — no editor
// Fill out with the live layout in defaults-table form (ios_bridge.m Com_Printf's it).
void Q2_iOS_LayoutDescription(char *out, int outsz) {
    if (!g_touchView || outsz <= 0) { if (outsz > 0) out[0] = 0; return; }
    strlcpy(out, g_touchView.layoutDescription.UTF8String, (size_t)outsz);
}
// Synthetic finger for the editor: phase 0 down / 1 move / 2 up / 3 zone-query. Returns
// nonzero for a grabbed control (down) or an inside-zone hit (query), 0 otherwise.
int Q2_iOS_FakeTouch(float nx, float ny, int phase) {
    return g_touchView ? ([g_touchView fakeTouchAt:CGPointMake(nx, ny) phase:phase] ? 1 : 0) : 0;
}

// Present the native iOS settings panel (ios_settings_ui.m) over the game. Reached from the
// engine menu's "iOS settings" entry and the touch chrome gear button (both run `ios_settings`).
extern UIViewController *Q2_iOS_NewSettingsVC(void);
void Q2_iOS_PresentSettings(void) {
    UIViewController *root = g_touchView.window.rootViewController;
    if (!root || root.presentedViewController) return;   // no window yet, or something already modal
    [root presentViewController:Q2_iOS_NewSettingsVC() animated:YES completion:nil];
}

// ---- Soft-keyboard key catcher ----------------------------------------------
// An invisible first-responder that forwards iOS keystrokes straight into the engine
// (Key_CharEvent / Key_Event), so the iOS keyboard types into the focused engine menu
// field (e.g. player name) or console — what you type shows in the game, not here.
extern void VID_iOS_KeyChar(int c);
extern void VID_iOS_KeyPress(int key);
@interface KeyCatcher : UIView <UIKeyInput>
@end
@implementation KeyCatcher
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\r') VID_iOS_KeyPress(13);   // K_ENTER
        else VID_iOS_KeyChar(c);
    }
}
- (void)deleteBackward { VID_iOS_KeyPress(8); }   // K_BACKSPACE
- (UIKeyboardAppearance)keyboardAppearance { return UIKeyboardAppearanceDark; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
@end

// ---- View controller --------------------------------------------------------
// Hosts the GLView and the 3-finger keyboard: the iOS keyboard types into the focused
// engine field (player name / console), with the game raised above the keyboard.
@interface GameVC : UIViewController
@property(nonatomic, strong) UIView *consoleBar;
@property(nonatomic, strong) KeyCatcher *keyCatcher;
- (void)installConsole;
@end
@implementation GameVC
- (BOOL)prefersStatusBarHidden { return YES; }
#if !TARGET_OS_VISION   // no device orientation / home indicator in the headset
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
#endif

// Call once after the view (GLView) is installed. Adds the 3-finger toggle + keyboard obs.
- (void)installConsole {
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleConsole)];
    g.numberOfTouchesRequired = 3; g.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:g];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kbShow:) name:UIKeyboardWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(kbHide:) name:UIKeyboardWillHideNotification object:nil];
}
- (void)toggleConsole {
    if (self.consoleBar) { [self dismissConsole]; return; }
    UIWindow *win = self.view.window;
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, win.bounds.size.height, win.bounds.size.width, 40)];
    bar.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.98];
    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont boldSystemFontOfSize:16]; done.tintColor = UIColor.whiteColor;
    done.frame = CGRectMake(win.bounds.size.width - 74, 4, 66, 32);
    [done addTarget:self action:@selector(dismissConsole) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:done];
    [win addSubview:bar];
    self.consoleBar = bar;
    KeyCatcher *kc = [[KeyCatcher alloc] initWithFrame:CGRectZero];
    [win addSubview:kc]; self.keyCatcher = kc;
    [kc becomeFirstResponder];   // shows the iOS keyboard → kbShow raises the game
}
- (void)dismissConsole {
    [self.keyCatcher resignFirstResponder];   // → kbHide lowers the game + removes the bar
}
- (void)kbShow:(NSNotification *)n {
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIWindow *win = self.view.window;
    CGFloat kbTop = win.bounds.size.height - kb.size.height, barH = self.consoleBar.frame.size.height;
    CGFloat raise = MIN(kb.size.height * 0.5, win.bounds.size.height * 0.3);   // modest lift so the field clears the keyboard
    [UIView animateWithDuration:0.25 animations:^{
        self.consoleBar.frame = CGRectMake(0, kbTop - barH, win.bounds.size.width, barH);
        self.view.transform = CGAffineTransformMakeTranslation(0, -raise);
    }];
}
- (void)kbHide:(NSNotification *)n {
    [UIView animateWithDuration:0.2 animations:^{
        self.view.transform = CGAffineTransformIdentity;
        if (self.consoleBar) self.consoleBar.frame = CGRectMake(0, self.view.window.bounds.size.height, self.view.window.bounds.size.width, 40);
    } completion:^(BOOL f){
        [self.consoleBar removeFromSuperview]; self.consoleBar = nil;
        [self.keyCatcher removeFromSuperview]; self.keyCatcher = nil;
    }];
}
@end

static int cmp_double(const void *x, const void *y) {   // ascending, for percentile sort
    double a = *(const double *)x, b = *(const double *)y;
    return (a > b) - (a < b);
}

// ---- App delegate -----------------------------------------------------------
@interface AppDelegate : UIResponder <UIApplicationDelegate, UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIViewController *gameVC;  // game VC (SwiftUI-hosted in the merged app; window root otherwise)
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, assign) BOOL engineStarted;
@property(nonatomic, weak) GLView *glView;
@property(nonatomic, assign) BOOL attract;
@property(nonatomic, assign) BOOL rerelease;    // rerelease data set (uses its own demomap attract chain)
@property(nonatomic, assign) int attractPhase;
@property(nonatomic, assign) int attractSaw;
@property(nonatomic, assign) int attractN;
@property(nonatomic, copy) NSString *pendingCommand;   // from a q2repro:// deep link
@property(nonatomic, strong) UIView *onboardView;      // first-run game-data intro
@property(nonatomic, strong) UILabel *fpsLabel;        // ios_fps on-screen counter
@property(nonatomic, assign) double fpsPrev, fpsSmooth;
@property(nonatomic, assign) BOOL menuWasActive;       // edge-detect menu open (clear nextserver)
@property(nonatomic, assign) BOOL benchmark;           // -benchmark launch arg: profile frame time
@property(nonatomic, assign) int shots;                // -shots launch arg: N periodic screenshots left
@property(nonatomic, assign) int attractDisc;          // consecutive idle+disconnected frames (attract debounce)
- (void)bringUpGameInWindow:(UIWindow *)window scale:(CGFloat)scale;   // shared iOS + visionOS bring-up
#if defined(Q2_XR_UI) && Q2_XR_UI
@property(nonatomic, strong) dispatch_source_t vrPadTimer;
- (void)startVRPadTimer;
- (void)stopVRPadTimer;
#endif
@end

// ==================== [R16] DISPLAY-LINK OWNERSHIP ====================
// While the immersive space is up, the VR ENGINE THREAD owns Qcommon_Frame and the ANGLE
// context (Q2_VR_StartEngineThread), and the main-thread display link is paused for exactly
// that reason — not as an optimisation. Anything that unpauses the link behind VR's back
// therefore puts a SECOND thread into Qcommon_Frame with no GL context of its own: torn
// refdefs (a duplicate of the world flashing beside the real one), entity lists rebuilt
// mid-render (bodies and items gone for a frame), per-eye light-stamp divergence, and GL
// errors from the context-less side. Whether such an unpause lands BEFORE or AFTER the entry
// pause is pure timing — which is precisely the "flicker comes and goes per VR entry, and a
// different eye each time" the headset reports.
//
// So: one funnel for every pause/unpause (q2_link_set), which REFUSES an unpause while the
// engine thread runs and records who asked; and a guard at the top of -tick that refuses to
// drive the engine from the main thread in VR, counts the ticks and re-pauses. Transitions
// are rare, so every one of them is logged with its reason.
//
// Q2_NO_MAINTICK_GUARD=1 compiles BOTH refusals out — the funnel's and -tick's — leaving only
// the counter and the MAINTICK log. That is the "before" arm of the A/B: the link really does
// get unpaused in VR and the main thread really does drive the engine, so the mechanism can be
// observed rather than assumed. It must never be defined in a shipping build.
#include <stdatomic.h>   // iOS too: the XR block above only includes it under Q2_XR_UI
static atomic_uint            q2_main_ticks_in_vr;   // main ticks that fired while VR owned the frame
static atomic_bool            q2_maintick_logged;    // one line per VR session, never per frame
static _Atomic(const char *)  q2_link_reason;        // who last touched the link

unsigned    Q2_VR_MainTicksInVR(void) { return atomic_load(&q2_main_ticks_in_vr); }
const char *Q2_VR_LinkReason(void)    { const char *r = atomic_load(&q2_link_reason); return r ? r : "boot"; }
void        Q2_VR_ResetMainTicksInVR(void) {
    atomic_store(&q2_main_ticks_in_vr, 0u);
    atomic_store(&q2_maintick_logged, false);
}

static int q2_vr_owns_frame(void) {
#if defined(Q2_XR_UI) && Q2_XR_UI
    return Q2_VR_EngineThreadRunning();
#else
    return 0;
#endif
}

static void q2_link_log(AppDelegate *app, const char *line) {
    if (app.engineStarted) Q2_VR_Log(line);
    else                   NSLog(@"[q2repro] %s", line);
}

static void q2_link_set(AppDelegate *app, BOOL paused, const char *reason) {
    if (!app.link) return;
    char line[192];
    atomic_store(&q2_link_reason, reason);
#if !defined(Q2_NO_MAINTICK_GUARD) || !Q2_NO_MAINTICK_GUARD
    if (!paused && q2_vr_owns_frame()) {
        // The whole point of the round: an unpause during VR is a bug wherever it comes from.
        snprintf(line, sizeof line,
                 "LINK unpause REFUSED reason=%s (VR engine thread owns the frame)", reason);
        q2_link_log(app, line);
        app.link.paused = YES;
        return;
    }
#endif   // Q2_NO_MAINTICK_GUARD also lifts the FUNNEL's refusal — otherwise the A/B's
         // "before" arm never lets the unpause through and cannot show the mechanism.
    BOOL was = app.link.paused;
    app.link.paused = paused;
    if (was != paused) {
        snprintf(line, sizeof line, "LINK paused=%d reason=%s", paused ? 1 : 0, reason);
        q2_link_log(app, line);
    }
}

#if TARGET_OS_VISION
// visionOS window lifecycle. A UIKit-native visionOS app runs in a proper 2D
// window in the Shared Space (crisper than the iPad-compat build). Scenes replace
// UIScreen — the window comes from the UIWindowScene, and its trait collection
// supplies the drawable scale for the CAMetalLayer that ANGLE renders into.
#if !defined(Q2_XR_UI) || !Q2_XR_UI
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)opts {
    if (![scene isKindOfClass:[UIWindowScene class]]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    UIWindow *w = [[UIWindow alloc] initWithWindowScene:ws];
    self.window = w;
    CGFloat scale = w.traitCollection.displayScale > 0 ? w.traitCollection.displayScale : 2.0;
    AppDelegate *app = (AppDelegate *)UIApplication.sharedApplication.delegate;
    [app bringUpGameInWindow:w scale:scale];
}
// Under the UIScene life cycle the UIApplicationDelegate activation callbacks don't
// fire — the scene gets them. Forward to the app delegate's existing handlers so
// engine activation, audio, config-persist and display-link pause work on visionOS.
- (void)fwd:(SEL)sel {
    id<UIApplicationDelegate> app = UIApplication.sharedApplication.delegate;
    if ([app respondsToSelector:sel]) {
        void (*imp)(id, SEL, UIApplication *) = (void *)[(id)app methodForSelector:sel];
        imp(app, sel, UIApplication.sharedApplication);
    }
}
- (void)sceneDidBecomeActive:(UIScene *)scene    { [self fwd:@selector(applicationDidBecomeActive:)]; }
- (void)sceneWillResignActive:(UIScene *)scene   { [self fwd:@selector(applicationWillResignActive:)]; }
- (void)sceneDidEnterBackground:(UIScene *)scene { [self fwd:@selector(applicationDidEnterBackground:)]; }
- (void)sceneWillEnterForeground:(UIScene *)scene{ [self fwd:@selector(applicationWillEnterForeground:)]; }
// Opt out of scene state restoration. visionOS's SwiftUI scene host was asserting in
// sceneItem(flush:) when saving/restoring this scene's state (the engine re-boots fresh
// each launch, so there is nothing to restore) — returning nil stops the save, and once a
// corrupt saved state exists it also breaks relaunch. nil here + shouldRestore:NO fixes both.
- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene { return nil; }
@end
#endif // !Q2_XR_UI — the merged 2D+3D app is SwiftUI-lifecycle: no SceneDelegate class AT ALL.
// (Compiling it out also defeats UIKit's persisted-scene-session trap: sessions saved by
// older UIKit-lifecycle installs store the delegate CLASS NAME and re-instantiate it on
// install-over; with the class gone the lookup fails and UIKit falls back to the SwiftUI
// configuration — the vkQuake-proven fix.)
#endif

@implementation AppDelegate

// Opt out of application state restoration entirely (see SceneDelegate note above): the engine
// re-boots fresh each launch, and a corrupt saved state was crashing launch on visionOS.
- (BOOL)application:(UIApplication *)application shouldSaveSecureApplicationState:(NSCoder *)coder { return NO; }
- (BOOL)application:(UIApplication *)application shouldRestoreSecureApplicationState:(NSCoder *)coder { return NO; }

// Shared bring-up: builds the game VC + GLView on an already-created, sized window
// and boots the engine. On iOS the app delegate creates the window (below); on
// visionOS the UIScene life cycle owns window creation, so SceneDelegate calls this.
- (void)bringUpGameInWindow:(UIWindow *)window scale:(CGFloat)scale {
    self.window = window;
    CGRect bounds = window.bounds;
    GameVC *vc = [GameVC new];
    window.rootViewController = vc;
    self.gameVC = vc;

    GLView *gl = [[GLView alloc] initWithFrame:bounds];
    gl.contentScaleFactor = scale;
    gl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gl.multipleTouchEnabled = YES;
    vc.view = gl;
    g_touchView = gl;   // console seams (touchedit / q2_faketouch) reach the editor through this
#if TARGET_OS_VISION
    // Claim the gamepad from the system. visionOS by default converts controller
    // presses into gaze-pinch UI events (A = tap where you look) and withholds
    // them from GCController; this interaction declares the view handles the
    // pad via the GameController framework, so the polling below gets real input.
    if (@available(visionOS 2.0, *)) {
        GCEventInteraction *padIntent = [[GCEventInteraction alloc] init];
        padIntent.handledEventTypes = GCUIEventTypeGamepad;
        [gl addInteraction:padIntent];
    }
#endif
    window.backgroundColor = UIColor.blackColor;
    [window makeKeyAndVisible];
    [vc installConsole];   // 3-finger keyboard console

    // On-screen touch buttons are owned + laid out by GLView (updateTouchUI each frame).
    self.glView = gl;
    [gl layoutIfNeeded];
    gl.layer.contentsScale = scale;   // CALayer property; the layer is CAMetalLayer under ANGLE
    VID_iOS_SetLayer((__bridge void *)gl.layer);

    // App Intent handoff (Siri/Shortcuts wrote a game name to launch).
    NSString *pl = [NSUserDefaults.standardUserDefaults stringForKey:@"q2_pending_launch"];
    if (pl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"q2_pending_launch"];
        self.pendingCommand = [pl isEqualToString:@"menu"] ? @"pushmenu main" : [NSString stringWithFormat:@"game %@", pl];
        self.attract = NO;
    }

    UIApplication.sharedApplication.idleTimerDisabled = YES;   // keep the display awake
    if ([self hasGameData]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startEngine]; });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self presentImporter]; });   // onboarding: import data first
    }
}

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
#if TARGET_OS_VISION
    // visionOS uses the UIScene life cycle: SceneDelegate creates the window and
    // calls -bringUpGameInWindow:scale:. Nothing to do at the app-delegate stage.
    (void)app; (void)opts;
    return YES;
#else
    CGRect bounds = UIScreen.mainScreen.bounds;
    UIWindow *w = [[UIWindow alloc] initWithFrame:bounds];
    [self bringUpGameInWindow:w scale:UIScreen.mainScreen.nativeScale];
    return YES;
#endif
}

// Install the bundled q2repro.menu into the writable game dir before the engine
// boots (the UI parses it at init). Version-marked first line: overwrite only when
// the app ships a newer menu, so a user's tweaks persist within a version.
// Install a bundled menu resource into <docs>/<gamedir>/q2repro.menu. Version-marked
// first line: overwrite only when the app ships a newer menu (user tweaks persist).
// Write into <homedir>/<gamedir> — the writable dir the engine's FS actually searches (homedir
// is searched before basedir). Writing to Documents/<gamedir> was the bug: on a rerelease install
// homedir is Documents/profile, so Documents/baseq2 is NOT on the search path and the custom menu
// (iOS Settings, mods, Action theming) silently never loaded → "No such menu: ios".
- (void)installMenuResource:(NSString *)resource intoGame:(NSString *)gamedir homedir:(NSString *)home {
    NSString *dir = [home stringByAppendingPathComponent:gamedir];
    NSString *src = [NSBundle.mainBundle pathForResource:resource ofType:@"menu"];
    if (!src) { NSLog(@"[q2repro] bundled %@.menu missing", resource); return; }
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundled = [NSString stringWithContentsOfFile:src encoding:NSUTF8StringEncoding error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:@"q2repro.menu"];
    NSString *existing = [NSString stringWithContentsOfFile:dst encoding:NSUTF8StringEncoding error:nil];
    NSString *bv = [bundled componentsSeparatedByString:@"\n"].firstObject;
    NSString *ev = [existing componentsSeparatedByString:@"\n"].firstObject;
    if (!existing || ![ev isEqualToString:bv]) {
        [bundled writeToFile:dst atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[q2repro] installed %@/q2repro.menu into homedir (%@)", gamedir, bv);
    }
}
- (void)installMenuInto:(NSString *)home {
    [self installMenuResource:@"q2repro" intoGame:@"baseq2" homedir:home];   // base menu
    [self installMenuResource:@"action"  intoGame:@"action" homedir:home];   // Action Quake theming (ships in IPA)
}

// ---- First-run game-data import (UIDocumentPicker) --------------------------
static NSString *DocsDir(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
- (BOOL)hasGameData {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *d = DocsDir();
    for (NSString *rel in @[@"baseq2/pak0.pak", @"baseq2/pak0.PAK", @"Q2Game.kpf", @"rerelease/baseq2/pak0.pak"])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:rel]]) return YES;
    return NO;
}
// Fable-style first-run intro: a branded full-screen card explaining that game data
// is required, with a folder picker and a re-check button. Stays up until data lands.
- (void)presentImporter {
    // An EMPTY Documents folder does not appear in the Files app at all (vkQuake
    // ios_onboarding.m parity): seed ONLY a guide file so "On My iPhone/Vision Pro ->
    // q2repro" exists immediately for the copy-in path. Never pre-create baseq2/ — Files
    // renames a user-dropped folder to "baseq2 2" when one already exists.
    NSFileManager *fm = NSFileManager.defaultManager; NSString *d = DocsDir();
    NSString *readme = [d stringByAppendingPathComponent:@"READ ME - put Quake II data here.txt"];
    if (![fm fileExistsAtPath:readme]) {
        [@"Copy your Quake II game data into this folder, then relaunch the app (or tap Check Again).\n\n"
          "Recommended - the 2023 re-release (Steam/GOG):\n"
          "  rerelease/baseq2/  plus its Q2Game.kpf next to baseq2\n\n"
          "Also works - the original release:\n"
          "  baseq2/            with pak0.pak inside\n\n"
          "You can also use the in-app \"Select Game Data Folder\" button instead - it copies for you.\n"
         writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    UIViewController *vc = self.gameVC;
    UIView *root = vc.view;
    UIView *card = [[UIView alloc] initWithFrame:root.bounds];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.backgroundColor = [UIColor colorWithRed:0.05 green:0.05 blue:0.06 alpha:1];
    self.onboardView = card;

    UILabel *title = [UILabel new];
    title.text = @"QUAKE II";
    title.font = [UIFont fontWithName:@"Copperplate-Bold" size:56] ?: [UIFont boldSystemFontOfSize:52];
    title.textColor = [UIColor colorWithRed:0.82 green:0.16 blue:0.07 alpha:1];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *body = [UILabel new];
    body.numberOfLines = 0;
    body.text = @"Game data required.\n\nChoose the folder holding your Quake II data — an original “baseq2”, the 2023 “rerelease” set, or a full Quake II directory. Files are copied to this device; you can add mods and packs later.";
    body.font = [UIFont systemFontOfSize:17];
    body.textColor = [UIColor colorWithWhite:0.80 alpha:1];
    body.textAlignment = NSTextAlignmentCenter;

    UIButton *pick = [UIButton buttonWithType:UIButtonTypeSystem];
    [pick setTitle:@"  Select Game Data Folder…  " forState:UIControlStateNormal];
    pick.titleLabel.font = [UIFont boldSystemFontOfSize:19];
    [pick setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    pick.backgroundColor = [UIColor colorWithRed:0.72 green:0.14 blue:0.06 alpha:1];
    pick.layer.cornerRadius = 10; pick.contentEdgeInsets = UIEdgeInsetsMake(14, 22, 14, 22);
    [pick addTarget:self action:@selector(onboardPick) forControlEvents:UIControlEventTouchUpInside];

    UIButton *again = [UIButton buttonWithType:UIButtonTypeSystem];
    [again setTitle:@"Check Again" forState:UIControlStateNormal];
    again.titleLabel.font = [UIFont systemFontOfSize:16];
    [again setTitleColor:[UIColor colorWithWhite:0.65 alpha:1] forState:UIControlStateNormal];
    [again addTarget:self action:@selector(onboardRecheck) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, body, pick, again]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [body.widthAnchor constraintLessThanOrEqualToConstant:560],
    ]];
    [root addSubview:card];
}
- (void)onboardPick {
    UIDocumentPickerViewController *p;
    if (@available(iOS 14.0, *))
        p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder]];
    else
        p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.folder"] inMode:UIDocumentPickerModeOpen];
    p.delegate = self; p.allowsMultipleSelection = NO;
    [self.gameVC presentViewController:p animated:YES completion:nil];
}
- (void)onboardRecheck {
    if ([self hasGameData]) { [self.onboardView removeFromSuperview]; self.onboardView = nil; [self startEngine]; }
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // The intro card stays up (data is required); user can pick again or Check Again.
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *src = urls.firstObject;
    // Progress spinner over the intro card while the copy runs.
    UIActivityIndicatorView *spin = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    spin.color = UIColor.whiteColor; spin.center = self.onboardView.center;
    [spin startAnimating]; [self.onboardView addSubview:spin];
    self.onboardView.userInteractionEnabled = NO;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self importFrom:src];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.onboardView removeFromSuperview]; self.onboardView = nil;
            [self startEngine];
        });
    });
}
// Copy the picked Quake 2 folder into Documents following the Steam rerelease layout:
// a rerelease set (has Q2Game.kpf) → Documents/ (baseq2 + Q2Game.kpf); an original
// baseq2 → Documents/baseq2/; any other mod/pack folder → Documents/<name>/.
- (void)importFrom:(NSURL *)folder {
    BOOL scoped = [folder startAccessingSecurityScopedResource];
    NSFileManager *fm = NSFileManager.defaultManager; NSString *docs = DocsDir();
    NSError *err = nil;
    void (^copyItem)(NSString *, NSString *) = ^(NSString *from, NSString *to) {
        NSError *e = nil;
        [fm removeItemAtPath:to error:NULL];
        [fm createDirectoryAtPath:[to stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![fm copyItemAtPath:from toPath:to error:&e]) NSLog(@"[q2repro] import copy %@ → %@ failed: %@", from, to, e);
        else NSLog(@"[q2repro] imported %@", to.lastPathComponent);
    };
    NSString *root = folder.path;
    NSArray *top = [fm contentsOfDirectoryAtPath:root error:&err];
    // Detect the shape of the picked folder.
    BOOL hasKpf = NO, hasBaseq2Dir = NO, hasLoosePak = NO;
    for (NSString *f in top) {
        NSString *low = f.lowercaseString;
        if ([low isEqualToString:@"q2game.kpf"]) hasKpf = YES;
        if ([low isEqualToString:@"baseq2"]) { BOOL d=NO; [fm fileExistsAtPath:[root stringByAppendingPathComponent:f] isDirectory:&d]; hasBaseq2Dir |= d; }
        if ([low hasPrefix:@"pak"] && [low hasSuffix:@".pak"]) hasLoosePak = YES;
    }
    // Case R: the picked folder IS a rerelease set (baseq2 + Q2Game.kpf together) →
    // keep it intact under Documents/rerelease/ (rerelease/baseq2 + rerelease/Q2Game.kpf).
    if (hasKpf && hasBaseq2Dir) {
        copyItem(root, [docs stringByAppendingPathComponent:@"rerelease"]);
    }
    // Case A: the picked folder is itself a baseq2 (loose paks) → Documents/baseq2
    else if (hasLoosePak) {
        copyItem(root, [docs stringByAppendingPathComponent:@"baseq2"]);
    }
    // Case B: a Quake 2 root — route each top-level item to the Steam-style layout.
    else {
        for (NSString *name in top) {
            NSString *from = [root stringByAppendingPathComponent:name];
            NSString *low = name.lowercaseString;
            BOOL dir = NO; [fm fileExistsAtPath:from isDirectory:&dir];
            // a subfolder that is itself a rerelease set → Documents/rerelease (intact)
            BOOL subKpf = NO, subBase = NO;
            if (dir) for (NSString *g in [fm contentsOfDirectoryAtPath:from error:nil]) {
                NSString *gl = g.lowercaseString;
                if ([gl isEqualToString:@"q2game.kpf"]) subKpf = YES;
                if ([gl isEqualToString:@"baseq2"]) subBase = YES;
            }
            if ([low isEqualToString:@"q2game.kpf"])        copyItem(from, [docs stringByAppendingPathComponent:@"rerelease/Q2Game.kpf"]);
            else if (subKpf && subBase)                     copyItem(from, [docs stringByAppendingPathComponent:@"rerelease"]);
            else if ([low isEqualToString:@"rerelease"])    copyItem(from, [docs stringByAppendingPathComponent:@"rerelease"]);
            else if ([low isEqualToString:@"baseq2"])       copyItem(from, [docs stringByAppendingPathComponent:@"baseq2"]);
            else if (dir)                                   copyItem(from, [docs stringByAppendingPathComponent:name]);  // mod/pack folder
        }
    }
    if (scoped) [folder stopAccessingSecurityScopedResource];
}

// basedir points at the rerelease set when present (so rerelease/baseq2 + rerelease/Q2Game.kpf
// resolve as the base game); otherwise Documents. homedir is always Documents (writable saves/cfg).
- (NSString *)computeBasedir {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *d = DocsDir();
    for (NSString *rel in @[@"rerelease/baseq2/pak0.pak", @"rerelease/baseq2/pak0.PAK"])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:rel]])
            return [d stringByAppendingPathComponent:@"rerelease"];
    return d;
}

// Is the 2023 rerelease data set present (Documents/rerelease/baseq2)? When it is, it wins over
// any original baseq2 in the Documents root.
- (BOOL)hasRerelease {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *d = DocsDir();
    for (NSString *rel in @[@"rerelease/baseq2/pak0.pak", @"rerelease/baseq2/pak0.PAK"])
        if ([fm fileExistsAtPath:[d stringByAppendingPathComponent:rel]]) return YES;
    return NO;
}

// A dedicated writable profile dir for config/saves — like the Steam rerelease (which keeps
// settings OUT of the game data), and unlike classic Quake (config in baseq2/). Keeping homedir
// here means <homedir>/baseq2 holds only config, so a vanilla Documents/baseq2 can no longer
// SHADOW the rerelease baseq2 (Quake searches homedir/baseq2 before basedir/baseq2).
- (NSString *)profileDir { return [DocsDir() stringByAppendingPathComponent:@"profile"]; }

// One-time migration: classic Q2 wrote config/saves into <homedir>/baseq2, which under the old
// homedir=Documents meant Documents/baseq2/{configs,save}. Now homedir is the separate profile
// dir, so carry those across once so the user's settings and saves aren't orphaned. Copies only
// the configs/ and save/ subdirs (never paks), and only when the profile copy doesn't exist yet.
- (void)migrateSettingsInto:(NSString *)profile {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldBase = [DocsDir() stringByAppendingPathComponent:@"baseq2"];
    NSString *newBase = [profile stringByAppendingPathComponent:@"baseq2"];
    for (NSString *sub in @[@"configs", @"save"]) {
        NSString *src = [oldBase stringByAppendingPathComponent:sub];
        NSString *dst = [newBase stringByAppendingPathComponent:sub];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:src isDirectory:&isDir] && isDir && ![fm fileExistsAtPath:dst]) {
            [fm createDirectoryAtPath:newBase withIntermediateDirectories:YES attributes:nil error:NULL];
            if ([fm copyItemAtPath:src toPath:dst error:NULL])
                NSLog(@"[q2repro] migrated %@ to profile dir", sub);
        }
    }
}

// ---- the boot config (Q-VR7) ------------------------------------------------------------
// THE BUG THIS EXISTS FOR, stated plainly: until this round no setting this app ever wrote
// survived a relaunch, on ANY platform. The shell persisted with `writeconfig
// q2reproconfig.cfg`, which writes `<home>/<game>/configs/q2reproconfig.cfg` — a *named
// saved config*, the engine's equivalent of "File > Save As". The file the engine execs at
// boot (FS_AddConfigFiles → COM_CONFIG_CFG) is `<home>/<game>/q2reproconfig.cfg`, at the game
// directory root, and on desktop only CL_WriteConfig writes it — from CL_Shutdown, which a
// mobile app never reaches because the OS kills it instead of quitting it. Two files, one
// written and never read, one read and never written.
//
// The fix is in two halves and BOTH are needed. Overlay 0026 adds `writeconfig_boot`, so
// from here on the shell writes the root file the engine actually reads, exactly the file
// desktop writes on quit. This function is the other half: the one-time carry-across of the
// legacy `configs/` file, so a player's accumulated settings finally take effect instead of
// being silently discarded on the day the read starts working.
//
// AND THE REASON IT IS NOT A COPY. That legacy file has been written blind for the app's
// whole life, including by 1.0.11.2, whose VR exit persisted the VR overrides into it
// (D-VR-R2.1 finding 2). Turning the read on with a plain copy would newly APPLY the exact
// damage 1.0.11.3 exists to stop — a bug that was cosmetically invisible for months would
// become visible on upgrade, which is the worst possible time. So the carry-across
// sanitises for that one signature, and only that one.
//
// THE SIGNATURE, AND WHY IT IS TWO ROWS AND NOT THREE (D-VR-R5.1). Through 1.0.11.7 the
// signature required all THREE of `gl_shadows "0"`, `viewsize "100"` and
// `gl_multisamples "0"`. That third row can never appear: gl_multisamples is CVAR_REFRESH
// (vendor/q2repro/src/refresh/main.c:1536), not CVAR_ARCHIVE, and the only writer of this
// file is CL_WriteConfig → `Cvar_WriteVariables(f, CVAR_ARCHIVE, false)`, which skips
// anything without the archive flag. So NO config the engine has ever written — including
// the ones 1.0.11.2 itself wrote — contains it, the match never fired, and .7 shipped a
// sanitiser that was dead code carrying .2 damage across verbatim. The signature is now the
// two rows .2 actually archived.
//
// AND WHAT THAT SIGNATURE REALLY MEANS. That same call passes modified=false, so
// Cvar_WriteVariables writes EVERY archived cvar including ones still at their default —
// there is no "only if changed" filter. viewsize is CVAR_ARCHIVE with default "100", so
// `seta viewsize "100"` is in essentially every config ever written. The two-row signature
// therefore degenerates, for all but the few players who moved viewsize off 100, to
// `gl_shadows "0"` alone. That is understood and accepted, not overlooked: the trade is a
// player who legitimately turned shadows off before .7 gets shadows reset to the default
// ONCE, visibly, and re-settable in one menu row (Options > Effects > ground shadows) —
// versus a .2 victim silently losing shadows forever with no way to know why. A one-time
// migration is exactly the place to take that trade.
//
// When the signature matches, those rows are DROPPED (so the engine's own defaults apply —
// no value is invented here) and everything else in the file is carried over untouched.
// When it does not match, the file is carried over verbatim. Nothing is deleted: the legacy
// file stays exactly where it was.
//
// Exactly-once by construction. The marker is the destination itself: a root config that
// already exists is either a migration that already happened or a file the engine wrote, and
// either way it is the live config and must not be touched. There is no separate flag to get
// out of sync with the filesystem.

// The .2 clobber signature, written by Cvar_WriteVariables as `seta <name> "<value>"`.
// NOT gl_multisamples: it is CVAR_REFRESH and is never archived — see the note above.
static NSArray<NSString *> *Q2BootCfgDamageSignature(void)
{
    static NSArray<NSString *> *sig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ sig = @[@"seta gl_shadows \"0\"", @"seta viewsize \"100\""]; });
    return sig;
}

// Drops the signature rows if ALL of them are present; otherwise returns the text unchanged.
// Shared by the legacy carry-across and by the .7-victim heal so the two can never drift.
static NSString *Q2BootCfgSanitise(NSString *text, NSString *header, BOOL *outSanitised)
{
    NSArray<NSString *> *sig = Q2BootCfgDamageSignature();
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([sig containsObject:l]) [seen addObject:l];
    }
    BOOL clobbered = (seen.count == sig.count);
    if (outSanitised) *outSanitised = clobbered;

    NSMutableString *out = [NSMutableString string];
    if (header.length) [out appendString:header];
    if (clobbered)
        [out appendString:@"// the 1.0.11.2 VR-exit clobber was found in it and those rows were\n"
                          @"// dropped, so the engine's own defaults apply to them.\n"];
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (clobbered && [sig containsObject:l]) continue;
        [out appendFormat:@"%@\n", raw];
    }
    return out;
}
static char s_bootcfg_report[512] = "BOOTCFGNOW state=notrun games=0 migrated=0 sanitized=0";

// Exposed for the harness (`q2bootcfg`) so the migration is assertable from a suite instead
// of inferred from a settings value that could be right for six other reasons.
void Q2_iOS_BootConfigReport(char *out, int outsz)
{
    if (out && outsz > 0) snprintf(out, (size_t)outsz, "%s", s_bootcfg_report);
}

// Returns: 0 nothing to do, 1 migrated verbatim, 2 migrated with the .2 signature sanitised.
- (int)migrateBootConfigForGame:(NSString *)gameDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root   = [gameDir stringByAppendingPathComponent:@"q2reproconfig.cfg"];
    NSString *legacy = [gameDir stringByAppendingPathComponent:@"configs/q2reproconfig.cfg"];
    if ([fm fileExistsAtPath:root]) return 0;          // live config already exists — hands off
    NSString *text = [NSString stringWithContentsOfFile:legacy encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) return 0;

    BOOL clobbered = NO;
    NSString *out = Q2BootCfgSanitise(text,
        @"// carried across from configs/q2reproconfig.cfg by the app shell.\n", &clobbered);
    NSError *err = nil;
    if (![out writeToFile:root atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        NSLog(@"[q2repro] boot config carry-across FAILED for %@: %@", gameDir, err);
        return 0;
    }
    NSLog(@"[q2repro] boot config carried across for %@ (sanitised=%d)", gameDir.lastPathComponent, clobbered);
    return clobbered ? 2 : 1;
}

// THE .7 VICTIM (D-VR-R5.1). The dead sanitiser shipped in 1.0.11.7, so a player who first
// launched .7 already ran the carry-across — the destination file EXISTS, and it holds the
// .2 damage, carried across verbatim. For them the migration above is over: its marker is
// the destination, and the destination is there. Fixing the signature alone would heal
// everyone who has not yet launched .7 and abandon everyone who has.
//
// So .8 does a second, separately-stamped one-shot pass over the LIVE config: if it still
// carries the two-row damage signature, drop those rows in place. Same signature, same
// helper, same trade — just applied to the file the earlier pass already moved.
//
// It needs its OWN marker and cannot reuse "the destination exists" (it always does here).
// A comment in the config would not survive: the engine rewrites this file from scratch on
// every writeconfig_boot and keeps no comments, so the marker would vanish and the heal
// would re-run — which matters, because after healing, a player who deliberately re-chooses
// shadows-off would have it taken away again on every launch, forever. A stamp file next to
// the config is durable and is never touched by the engine. It is written whether or not
// anything was healed, so this is strictly a one-shot per game directory.
//
// Returns 1 if damage was actually found and dropped, 0 otherwise.
- (int)healBootConfigForGame:(NSString *)gameDir {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root  = [gameDir stringByAppendingPathComponent:@"q2reproconfig.cfg"];
    NSString *stamp = [gameDir stringByAppendingPathComponent:@".q2repro-bootcfg-heal"];
    if ([fm fileExistsAtPath:stamp]) return 0;         // this pass already ran here

    int healed = 0;
    NSString *text = [NSString stringWithContentsOfFile:root encoding:NSUTF8StringEncoding error:NULL];
    if (text.length) {
        BOOL clobbered = NO;
        NSString *out = Q2BootCfgSanitise(text, nil, &clobbered);
        if (clobbered) {
            NSError *err = nil;
            if ([out writeToFile:root atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
                healed = 1;
                NSLog(@"[q2repro] boot config healed in place for %@", gameDir.lastPathComponent);
            } else {
                NSLog(@"[q2repro] boot config heal FAILED for %@: %@", gameDir, err);
                return 0;                              // no stamp — retry on the next launch
            }
        }
    }
    [@"1" writeToFile:stamp atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return healed;
}

- (void)migrateBootConfigsIn:(NSString *)home {
    NSFileManager *fm = NSFileManager.defaultManager;
    int games = 0, migrated = 0, sanitized = 0, healed = 0;
    // Every game directory under homedir, not just baseq2: a mod switch gives the mod its own
    // config, and a player who set up a mod has the same right to keep those settings.
    for (NSString *name in [fm contentsOfDirectoryAtPath:home error:NULL]) {
        NSString *g = [home stringByAppendingPathComponent:name];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:g isDirectory:&dir] || !dir || [name hasPrefix:@"."]) continue;
        games++;
        int r = [self migrateBootConfigForGame:g];
        if (r) migrated++;
        if (r == 2) sanitized++;
        // A fresh carry-across has just been sanitised with the current signature, so stamp
        // it too — the heal below is only ever for configs an EARLIER build moved.
        healed += [self healBootConfigForGame:g];
    }
    snprintf(s_bootcfg_report, sizeof(s_bootcfg_report),
             "BOOTCFGNOW state=ran games=%d migrated=%d sanitized=%d healed=%d home=%s",
             games, migrated, sanitized, healed, home.fileSystemRepresentation);
}

// q2repro:// deep links (Shortcuts / Siri / home-screen). Examples:
//   q2repro://menu · q2repro://play · q2repro://map/base1 · q2repro://action (launch a mod).
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)opts {
    NSString *host = url.host.lowercaseString;
    NSString *arg = url.pathComponents.count > 1 ? url.pathComponents[1] : nil;
    NSString *cmd = nil;
    if ([host isEqualToString:@"menu"])                              cmd = @"pushmenu main";
    else if ([host isEqualToString:@"play"] || [host isEqualToString:@"newgame"]) cmd = @"pushmenu singleplayer";
    else if ([host isEqualToString:@"map"] && arg)                   cmd = [NSString stringWithFormat:@"map %@", arg];
    else if ([host isEqualToString:@"mod"] && arg)                   cmd = [NSString stringWithFormat:@"game_apply %@", arg];
    else if (host.length)                                           cmd = [NSString stringWithFormat:@"game_apply %@", host]; // q2repro://action
    if (!cmd) return NO;
    self.attract = NO;
    if (self.engineStarted) VID_iOS_Command(cmd.UTF8String);
    else self.pendingCommand = cmd;
    return YES;
}

// Build baseq2/q2repro_mods.menu listing installed mods/packs (folders with paks),
// filtered by a curated allowlist (baseq2/mods.lst) when present — so junk paks
// auto-downloaded from servers never clutter the list. Tapping a mod switches to it.
- (void)generateModsMenuInto:(NSString *)home {
    NSFileManager *fm = NSFileManager.defaultManager; NSString *docs = DocsDir();
    NSString *lst = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"baseq2/mods.lst"]
                                              encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *allow = nil;
    if (lst) { allow = [NSMutableArray array];
        for (NSString *l in [lst componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (t.length && ![t hasPrefix:@"//"]) [allow addObject:t.lowercaseString];
        } }
    NSMutableArray *mods = [NSMutableArray array];
    for (NSString *name in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        NSString *low = name.lowercaseString;
        if ([low isEqualToString:@"baseq2"] || [low isEqualToString:@"rerelease"] || [name hasPrefix:@"."]) continue;
        NSString *path = [docs stringByAppendingPathComponent:name];
        BOOL dir = NO; if (![fm fileExistsAtPath:path isDirectory:&dir] || !dir) continue;
        BOOL isMod = NO;
        for (NSString *f in [fm contentsOfDirectoryAtPath:path error:nil]) {
            NSString *fl = f.lowercaseString;
            if ([fl hasSuffix:@".pak"] || [fl hasSuffix:@".pkz"] || [fl hasSuffix:@".pk3"] || [fl hasSuffix:@".kpf"] || [fl containsString:@"game"]) { isMod = YES; break; }
        }
        if (!isMod) continue;
        if (allow && ![allow containsObject:low]) continue;   // curated allowlist filter
        [mods addObject:name];
    }
    // Rerelease expansions are launched by their shipped `newgame_*` alias (plays that
    // campaign's intro cinematic → first map — the Steam experience), NOT a classic game_apply
    // mod switch. Map the mod dir name → [themed title, newgame command].
    NSDictionary *episodes = @{
        @"xatrix":  @[@"The Reckoning",       @"newgame_xatrix"],
        @"rogue":   @[@"Ground Zero",         @"newgame_rogue"],
        @"mgu":     @[@"Call of the Machine", @"newgame_mg2"],
        @"machine": @[@"Call of the Machine", @"newgame_mg2"],
        @"q64":     @[@"Quake II 64",         @"newgame_n64"],
        @"n64":     @[@"Quake II 64",         @"newgame_n64"],
    };
    NSMutableString *m = [NSMutableString stringWithString:@"begin mods\n    title \"MODS AND PACKS\"\n"];
    if (mods.count == 0) [m appendString:@"    action \"(no mods installed)\" \"pushmenu options\"\n"];
    for (NSString *mod in mods) {
        NSArray *ep = episodes[mod.lowercaseString];
        if (ep) [m appendFormat:@"    action \"%@\" \"forcemenuoff; %@\"\n", ep[0], ep[1]];   // expansion: intro + campaign
        else    [m appendFormat:@"    action \"%@\" \"game_apply %@; pushmenu main\"\n", mod, mod];  // classic mod
    }
    [m appendString:@"end\n"];
    // Written into homedir/baseq2 (searched, and next to the q2repro.menu that includes it).
    [m writeToFile:[home stringByAppendingPathComponent:@"baseq2/q2repro_mods.menu"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[q2repro] mods menu: %lu mod(s)%@", (unsigned long)mods.count, allow ? @" (allowlist)" : @"");
}

- (void)startEngine {
    if (self.engineStarted) return;
    self.engineStarted = YES;

    NSString *docs = DocsDir();
    const char *cdocs = docs.fileSystemRepresentation; (void)cdocs;
    // [Phase 2 acceptance] -vanilla (env Q2_VANILLA): boot ORIGINAL baseq2 from Documents/vanilla.
    BOOL vanilla = getenv("Q2_VANILLA") != NULL;
    // Rerelease wins whenever its data is present: basedir points at the rerelease set (its
    // baseq2 + Q2Game.kpf become THE game); else the original baseq2 in Documents. com_rerelease
    // follows the data — it was hardwired to 1, which ran rerelease game logic even on vanilla
    // data (the source of the "am I on vanilla or rerelease?" confusion + odd crosshair).
    BOOL hasRR = [self hasRerelease] && !vanilla;
    NSString *base = vanilla ? [docs stringByAppendingPathComponent:@"vanilla"]
                             : (hasRR ? [docs stringByAppendingPathComponent:@"rerelease"] : docs);
    // homedir = a separate profile dir (Steam-style), NOT inside the game data — see -profileDir.
    // This is what stops a vanilla Documents/baseq2 from shadowing the rerelease baseq2. Migrate
    // the old in-baseq2 settings across once so nothing is lost.
    NSString *home = vanilla ? base : [self profileDir];
    if (!vanilla) [self migrateSettingsInto:home];
    // Q-VR7: unify the two config paths BEFORE the engine boots — FS_AddConfigFiles execs the
    // root config during Qcommon_Init, so a carry-across that ran after it would take effect
    // one launch late. See -migrateBootConfigsIn: for the .2 sanitiser and why it is there.
    [self migrateBootConfigsIn:home];

    // Install the bundled menus + generate the mods list INTO homedir (must precede engine boot;
    // the UI parses them at init). This has to run AFTER `home` is known — writing them to the
    // wrong dir is what broke the iOS Settings menu on rerelease installs.
    [self installMenuInto:home];
    [self generateModsMenuInto:home];

    const char *cbase = base.fileSystemRepresentation;
    const char *chome = home.fileSystemRepresentation;
    static char *argv[48]; int argc = 0;
    argv[argc++] = strdup("q2repro");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("logfile"); argv[argc++] = strdup("1");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("logfile_flush"); argv[argc++] = strdup("1");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("basedir"); argv[argc++] = strdup(cbase);
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("homedir"); argv[argc++] = strdup(chome);
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("com_rerelease"); argv[argc++] = strdup(hasRR ? "1" : "0");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("scr_demobar"); argv[argc++] = strdup("0");    // clean attract demos
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("vid_fullscreen"); argv[argc++] = strdup("1"); // draws the engine ch1 menu cursor
    self.rerelease = hasRR;
    // Attract demo loop (BOTH modes): the launch screen plays the DEMOS. Steam cycles demos at
    // idle; the story intro (ntro.cin) belongs to New Game / Unit 1, not the launch screen — so
    // it no longer plays on boot (which also removes the double-intro). demo1/demo2 exist in both
    // vanilla and rerelease data; old-protocol vanilla demos play via overlay 0017. d1 is aliased
    // to the loop so action.menu's "back to Quake II" (which runs d1) starts the demos too — the
    // rerelease's own d1 is `demomap idlog.cin`, and idlog isn't in the shipped data.
    argv[argc++] = strdup("+alias"); argv[argc++] = strdup("attract1"); argv[argc++] = strdup("demo demo1; set nextserver attract2");
    argv[argc++] = strdup("+alias"); argv[argc++] = strdup("attract2"); argv[argc++] = strdup("demo demo2; set nextserver attract1");
    argv[argc++] = strdup("+alias"); argv[argc++] = strdup("d1");       argv[argc++] = strdup("attract1");
    // No +map: boot into the attract sequence (intro → demo loop → tap for menu), driven from
    // tick. self.attract enables it; a launch URL/deeplink can override.
    self.attract = YES;
    argv[argc] = NULL;

    NSLog(@"[q2repro] Qcommon_Init basedir=%s home=%s rerelease=%d", cbase, chome, hasRR);
    Qcommon_Init(argc, argv);
    VID_iOS_RegisterCvars();   // ios_* settings cvars (CVAR_ARCHIVE)
    Q2_iOS_AudioBoot();        // route-change/interruption observers (the category itself
                               // was already set from S_Init — see snddma_coreaudio.m)
    // Default pad layout for vanilla-pak installs (config.cfg already exec'd, so user
    // rebinds win). Needed at boot — not just pad-connect — because the TOUCH weapon
    // wheel resolves through the right_shoulder bind too.
    VID_iOS_EnsureGamepadBinds();
    // A stray archived gl_modulate_entities=3 (engine default 1) lit entity models at
    // gl_modulate(2)×3 = 6× vs the world's 2× — guns/enemies/items blew out while the world
    // looked fine. Reset to default so models match world brightness.
    VID_iOS_Command("set gl_modulate_entities 1");
    // com_rerelease follows the DATA, and it has to be re-asserted here because it is an
    // archived cvar and the boot config is exec'd during Qcommon_Init — AFTER the `+set` on
    // the command line. Before R5 that did not matter, because the config was never read;
    // now it is, and a player who once had the rerelease set installed and then removed it
    // would boot with com_rerelease 1 on vanilla data — which is precisely the "am I on
    // vanilla or rerelease?" confusion the data-derived choice exists to prevent. The shell
    // knows what is on disk; the config only knows what used to be.
    VID_iOS_Command(hasRR ? "set com_rerelease 1" : "set com_rerelease 0");
    NSLog(@"[q2repro] engine initialized; starting display link");

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self applyRefreshRate];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    q2_link_set(self, NO, "engine start");   // [R16] record the reason; the link is already live

    CL_Activate(ACT_ACTIVATED);
    if ([NSProcessInfo.processInfo.arguments containsObject:@"-benchmark"]) {
        // [Phase 3] deterministic perf run: force off the auto-menu, timedemo demo1, profile.
        self.attract = NO; self.benchmark = YES;
        VID_iOS_Command("forcemenuoff");
        VID_iOS_Command("set timedemo 1");
        VID_iOS_Command("demo demo1");
    } else if (getenv("Q2_SHOTS")) {
        // [Phase 2] auto-capture screenshots across the demo (glReadPixels PNG) for artifacts.
        // Env var (via DEVICECTL_CHILD_Q2_SHOTS) — devicectl parses a leading-dash arg itself.
        self.shots = 8;   // captured in tick, spaced out
    } else if (vanilla) {   // [Phase 2 acceptance] boot original baseq2 → base1
        self.attract = NO;
        VID_iOS_Command("forcemenuoff");
        VID_iOS_Command("map base1");
        if (getenv("Q2_SHOTS2")) self.shots = 6;   // optionally capture the vanilla boot too
    } else if (getenv("Q2_MAP")) {   // [Phase 2] load an arbitrary map + capture (sky/water/fog checks)
        self.attract = NO;
        VID_iOS_Command("forcemenuoff");
        VID_iOS_Command([NSString stringWithFormat:@"map %s", getenv("Q2_MAP")].UTF8String);
        self.shots = 6;
    } else if (getenv("Q2_CMD")) {   // [dev] run console command(s) at boot; ';' splits like the menu Cbuf
        if (getenv("Q2_KEEP")) self.attractPhase = 2; else self.attract = NO;  // Q2_KEEP: leave attract running
        VID_iOS_Command("forcemenuoff");
        for (NSString *c in [@(getenv("Q2_CMD")) componentsSeparatedByString:@";"])
            VID_iOS_Command([c stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].UTF8String);
    } else if (self.pendingCommand) {   // deep-link launch overrides the attract sequence
        self.attract = NO;
        VID_iOS_Command(self.pendingCommand.UTF8String);
        self.pendingCommand = nil;
    }
}

// Poll a connected MFi/Xbox/PlayStation pad each frame and drive the same
// move/look/button bridge as touch. Only touches move/look when a stick is
// actually deflected, so an idle controller doesn't fight the touch joystick.
- (void)pollController {
    static BOOL hadPad = NO;
    static unsigned ensureTick = 0;
#if defined(Q2_XR_UI) && Q2_XR_UI
    // THE ONE-FIST TRAP (charter D5 context 3). The SAME `SpatialGamepad` declaration that
    // makes the Sense pair trackable makes GameController hand each half back as its own
    // ordinary gamepad — and `firstObject` then drives the entire game from one hand, weapon
    // wheel and bind table included. So the pad we poll is the first NON-spatial one. The
    // filter is deliberately conservative (it fires only when a spatial controller carries a
    // name and no ordinary one does), so its failure mode is the status quo, never a dead pad.
    // The declaration and this filter ship in the SAME build, always.
    GCExtendedGamepad *gp = nil;
    for (GCController *c in GCController.controllers) {
        const char *nm = (c.vendorName.length ? c.vendorName : @"MFi Gamepad").UTF8String;
        if (Q2_VR_SenseShouldIgnoreGamepad(nm)) continue;
        if (c.extendedGamepad) { gp = c.extendedGamepad; break; }
    }
    // The Sense pair's own contexts: the menu pump and the flat-mode gamepad merge. Runs
    // whether or not an ordinary pad is present, and returns immediately while VR gameplay
    // owns the pair (the engine thread drains the same edge detector there).
    Q2_VR_HandsUIFrame();
#else
    GCExtendedGamepad *gp = GCController.controllers.firstObject.extendedGamepad;
#endif
    // [R7b item 7] Reconcile the menu pause. BEFORE the `if (!gp) return` below, deliberately:
    // in a headset there is usually no ordinary gamepad at all, and a reconciliation that only
    // ran when one was connected would strand a paused game behind a menu the Sense pair
    // closed. Edge-triggered inside, so this is a cheap read on the poll and a producer item
    // only on a transition.
    Q2_iOS_MenuPauseTick();
    if (!gp) {
#if defined(Q2_XR_UI) && Q2_XR_UI
        if (hadPad) Q2_VR_PadClearPad();   // the pad's slot in the merged snapshot, not the hands'
#endif
        hadPad = NO; return;
    }

    // Keep the default pad layout applied while a pad is present: on connect, then
    // every ~256 frames — `game` switches re-exec a default.cfg (vanilla ones open
    // with `unbindall`) and per-gamedir config.cfg means a first visit to an
    // expansion has no saved pad binds. Only ever touches unbound keys.
    if (!hadPad) { hadPad = YES; ensureTick = 0; }
    if ((ensureTick++ & 255) == 0) VID_iOS_EnsureGamepadBinds();

    // Menu button (Start/☰) — ONE edge detector across both modes. Two separate detectors
    // double-toggled: opening the menu switched modes mid-hold and the other block's stale flag
    // fired again, flashing the menu open→closed on the first press.
    if (@available(iOS 13.0, *)) {
        // [R7b items 6+7] ONE Start body, shared with the Sense pair: skip a cinematic if one
        // is playing, otherwise toggle the menu AND pause a live single-player game. It used
        // to call VID_iOS_ToggleMenu directly and the world kept running behind the menu.
        static BOOL pmenu = NO; BOOL c = gp.buttonMenu.isPressed;
        if (c && !pmenu) VID_iOS_PadStartButton();
        pmenu = c;
    }
    // [R7b item 6] The face buttons skip a cinematic too, on this stack as on the Sense pair —
    // the iPhone has always skipped on a screen tap and a controller player had no way in.
    if (VID_iOS_PassiveState() == 2 && !VID_iOS_MenuActive()) {
        static BOOL pskip = NO;
        BOOL c = gp.buttonA.isPressed || gp.buttonB.isPressed ||
                 gp.rightTrigger.value > 0.3f || gp.leftTrigger.value > 0.3f;
        if (c && !pskip) VID_iOS_SkipCinematic();
        pskip = c;
        return;                 // a movie takes no gameplay input
    }

    // Menu mode: dpad/stick navigate, A selects, B backs.
    if (VID_iOS_MenuActive()) {
        static BOOL mu=NO, md=NO, ml=NO, mr=NO, ma=NO, mb=NO;
        #define MEDGE(cur, prev, act) do { BOOL c_=(cur); if (c_ && !prev) { VID_iOS_MenuKey((act), YES); VID_iOS_MenuKey((act), NO); } prev=c_; } while(0)
        MEDGE(gp.dpad.up.isPressed    || gp.leftThumbstick.yAxis.value >  0.5f, mu, IOS_MENU_UP);
        MEDGE(gp.dpad.down.isPressed  || gp.leftThumbstick.yAxis.value < -0.5f, md, IOS_MENU_DOWN);
        MEDGE(gp.dpad.left.isPressed  || gp.leftThumbstick.xAxis.value < -0.5f, ml, IOS_MENU_LEFT);
        MEDGE(gp.dpad.right.isPressed || gp.leftThumbstick.xAxis.value >  0.5f, mr, IOS_MENU_RIGHT);
        MEDGE(gp.buttonA.isPressed, ma, IOS_MENU_ENTER);
        MEDGE(gp.buttonB.isPressed, mb, IOS_MENU_BACK);
        #undef MEDGE
        return;
    }

    // Game (and bind-capture): sticks are analog; buttons go through the engine BIND
    // system as KEX virtual keys, so the rerelease default.cfg layout — weapon wheel
    // (right_shoulder "+wheel") included — works unmodified and stays rebindable.
    float lx = gp.leftThumbstick.xAxis.value, ly = gp.leftThumbstick.yAxis.value;
    static BOOL moving = NO;
    if (fabsf(lx) > 0.15f || fabsf(ly) > 0.15f) { VID_iOS_AnalogMove(ly, lx); moving = YES; }
    else if (moving) { VID_iOS_AnalogMove(0, 0); moving = NO; }

    float rx = gp.rightThumbstick.xAxis.value, ry = gp.rightThumbstick.yAxis.value;
    float csx = VID_iOS_SensX() / 3.0f, csy = VID_iOS_SensY() / 3.0f;   // neutral 3 = 1.0×
    float iy = VID_iOS_InvertY() ? -1.0f : 1.0f;
    if (fabsf(rx) < 0.12f) rx = 0;   // deadzone
    if (fabsf(ry) < 0.12f) ry = 0;
#if defined(Q2_XR_UI) && Q2_XR_UI
    if (Q2_VR_Mode() == 2) {
        // In VR the right stick does NOT drive the view. The head owns pitch absolutely — a
        // stick that could also pitch the camera would put the horizon somewhere the player's
        // neck says it is not — and yaw goes through the snap/smooth turn machinery, which
        // integrates against the engine's own frame time rather than this timer's.
        Q2_VR_PadSticks(lx, ly, rx, ry, 0);
    } else
#endif
    // rate look each frame (0 when centered); engine scales by turn-speed and routes to
    // the weapon wheel by DIRECTION when it's open (GTA-style select).
    VID_iOS_LookAnalog(rx * csx, iy * ry * csy);

    static BOOL st[16] = {0};
    #define GK(i, cur, key) do { BOOL c_ = (cur); if (c_ != st[i]) { VID_iOS_KeyEvent((key), c_); st[i] = c_; } } while (0)
    GK(0,  gp.buttonA.isPressed,         K_A_BUTTON);
    GK(1,  gp.buttonB.isPressed,         K_B_BUTTON);
    GK(2,  gp.buttonX.isPressed,         K_X_BUTTON);
    GK(3,  gp.buttonY.isPressed,         K_Y_BUTTON);
    GK(4,  gp.leftShoulder.isPressed,    K_LEFT_SHOULDER);
    GK(5,  gp.rightShoulder.isPressed,   K_RIGHT_SHOULDER);
    GK(6,  gp.leftTrigger.value  > 0.3f, K_LEFT_TRIGGER);
    GK(7,  gp.rightTrigger.value > 0.3f, K_RIGHT_TRIGGER);
    GK(8,  gp.dpad.up.isPressed,          K_DPAD_UP);
    GK(9,  gp.dpad.down.isPressed,        K_DPAD_DOWN);
    GK(10, gp.dpad.left.isPressed,        K_DPAD_LEFT);
    GK(11, gp.dpad.right.isPressed,       K_DPAD_RIGHT);
    if (@available(iOS 12.1, *)) {
        GK(12, gp.leftThumbstickButton.isPressed,  K_LEFT_STICK);
        GK(13, gp.rightThumbstickButton.isPressed, K_RIGHT_STICK);
    }
    #undef GK
}

#if defined(Q2_XR_UI) && Q2_XR_UI
// ---- the VR pad driver ---------------------------------------------------------------
// R1 descoped gamepad-in-VR for a specific reason: under `.full` immersion visionOS stops
// ticking the hidden 2D window's CADisplayLink, and that link is what polled the pad. The
// polling therefore needs a home that does not depend on a window being rendered.
//
// A main-queue timer, and not the engine thread. GameController's controller list is
// mutated from the main queue (connect/disconnect notifications post there), so polling it
// from the engine thread would be an unsynchronised read of an array UIKit can replace
// mid-iteration. A valueChangedHandler would run on the same queue anyway, and a stick held
// at a constant deflection emits no events at all — so the INTEGRATION (smooth turn, snap
// hysteresis) would still have to live on the engine frame, where the engine's own dt is.
// The split is therefore: sample on main at a fixed cadence, integrate on the engine frame.
// Everything it writes into the engine goes through the producer funnel R1 built for
// exactly this.
//
// `padticks` is a heartbeat, reported in MOVENOW: a simulator run in a real `.full` space
// can then PROVE that this driver keeps running when the display link does not, which is
// the entire claim the round rests on.
static atomic_int q2_vr_pad_ticks;
int Q2_VR_PadTicks(void) { return atomic_load(&q2_vr_pad_ticks); }

- (void)startVRPadTimer {
    if (self.vrPadTimer) return;
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                 dispatch_get_main_queue());
    // 90 Hz: the headset's own cadence. Sampling slower makes a snap-turn flick missable;
    // sampling faster buys nothing, because the integration is on the engine frame.
    dispatch_source_set_timer(t, DISPATCH_TIME_NOW, NSEC_PER_SEC / 90, NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(t, ^{
        atomic_fetch_add(&q2_vr_pad_ticks, 1);
        [weakSelf pollController];
    });
    dispatch_resume(t);
    self.vrPadTimer = t;
    Q2_VR_Log("VRPAD main-queue driver started (the display link is paused in VR)");
}

- (void)stopVRPadTimer {
    if (!self.vrPadTimer) return;
    dispatch_source_cancel(self.vrPadTimer);
    self.vrPadTimer = nil;
    Q2_VR_Log("VRPAD main-queue driver stopped");
}
#endif

- (void)applyRefreshRate {
    if (@available(iOS 15.0, *)) {
        int fps = VID_iOS_DisplayFps();   // 0 = native max (120 on ProMotion)
        self.link.preferredFrameRateRange = (fps > 0)
            ? CAFrameRateRangeMake(fps, fps, fps)
            : CAFrameRateRangeMake(60, 120, 120);
    }
}

// Boot attract: id intro cinematic → self-looping demo (d1/d2 aliases run nextserver).
// Whenever the client is idle+disconnected (boot, a demo ended without re-arming, or the
// user returned from a game / "back to Quake II"), (re)start the loop. A tap skips the
// intro / opens the menu (handled in GLView from PassiveState).
- (void)driveAttract {
    if (!self.attract) return;                        // disabled: deep-link launch, or user engaged
    if (self.attractN > 0) { self.attractN--; return; } // debounce: let the last command take effect
    // Boot: the engine auto-pushes the main menu when disconnected — force it off and start
    // the id intro cinematic so the app opens on the attract, not a menu. (Must run BEFORE the
    // menu-disable check below, or the boot auto-menu would kill the attract instantly.)
    if (self.attractPhase == 0) {
        if (!VID_iOS_Disconnected()) return;          // wait until the client is ready
        VID_iOS_Command("forcemenuoff");
        VID_iOS_Command("demo demo1");                // Steam-style: the launch screen plays a DEMO,
        self.attractPhase = 1; self.attractN = 30; return;   // not the story intro (that's New Game)
    }
    // Arm the loop so when demo1 ends it chains to demo2 and loops (attract1/attract2 aliases).
    // Set nextserver a beat after the demo started (so its own load doesn't clear it).
    if (self.attractPhase == 1) {
        VID_iOS_Command("set nextserver attract2");
        self.attractPhase = 2; return;
    }
    // Phase 2 (intro done, demo loop self-sustaining via `nextserver`): the FIRST menu the user
    // opens means they're engaging — stop managing the attract so nothing can hijack the map a
    // menu action starts. The demo keeps looping behind the menu on its own; "back to Quake II"
    // replays it with an explicit `d1`.
    if (VID_iOS_MenuActive()) { self.attract = NO; return; }
}

- (void)tick {
    double t0 = self.benchmark ? CACurrentMediaTime() : 0;
    // Before anything that can early-out: the intro cinematic and the attract demo
    // make sound long before there is a live game to gate on.
    Q2_iOS_AudioTick();
#if defined(Q2_XR_UI) && Q2_XR_UI
    // [R16] THE MAIN-TICK GUARD. If the VR engine thread is running it owns Qcommon_Frame
    // and the GL context; a link that got unpaused behind VR's back must not double-drive
    // the engine from here. Count it, say it once per VR session with the reason the link
    // was unpaused, and put the link back where entry left it.
    if (Q2_VR_EngineThreadRunning()) {
        unsigned n = atomic_fetch_add(&q2_main_ticks_in_vr, 1u) + 1u;
        if (!atomic_exchange(&q2_maintick_logged, true)) {
            char line[192];
            snprintf(line, sizeof line, "MAINTICK in VR: link was unpaused by %s (tick %u) - %s",
                     Q2_VR_LinkReason(), n,
#if !defined(Q2_NO_MAINTICK_GUARD) || !Q2_NO_MAINTICK_GUARD
                     "engine NOT driven from main, link re-paused"
#else
                     "GUARD COMPILED OUT - main is about to drive the engine too"
#endif
                     );
            Q2_VR_Log(line);
        }
        // What survives the guard, and why nothing else does. Q2_iOS_AudioTick (above) is the
        // only per-tick call that is safe here: it touches AVAudioSession and the mixer gain
        // and never the client or a cvar. NOT pollController — the 90 Hz VRPAD timer already
        // polls the pad in VR, and a second poller would double-count sticks. NOT Q2_VR_Tick —
        // the VR engine thread calls it itself every frame (q2_vr_glue.m:920), and its yaw
        // trace / autocapture / map watch read engine state, which is the very thing this
        // guard exists to keep one thread away from.
#if !defined(Q2_NO_MAINTICK_GUARD) || !Q2_NO_MAINTICK_GUARD
        q2_link_set(self, YES, "maintick guard");
        return;
#endif
    }
#endif
    [self pollController];
    double f0 = self.benchmark ? CACurrentMediaTime() : 0;
#if defined(Q2_XR_UI) && Q2_XR_UI
    if (VID_iOS_XR3_Active()) {
        // Stereo: complete frame twice, same game time, eye matrices only (overlays 0016/0020).
        // Settings are read live so the panel sliders take effect immediately.
        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        // Stereo Depth is stored as PERCENT of the proven default (100% = 2.5 world units
        // total separation ≈ IPD at inch scale — vkQuake's shipped value).
        float pct  = [d objectForKey:@"xr_sep_pct"] ? (float)[d floatForKey:@"xr_sep_pct"] : 100.0f;
        float sep  = 1.25f * pct / 100.0f;   // half-separation
        float conv = [d objectForKey:@"xr_conv"] ? (float)[d floatForKey:@"xr_conv"] : 240.0f;   // 20 ft
        static int lastGun = -1;
        int hideGun = [d objectForKey:@"xr_hidegun"] ? [d boolForKey:@"xr_hidegun"] : 0;
        if (hideGun != lastGun) { VID_iOS_Command(hideGun ? "set cl_gun 0" : "set cl_gun 1"); lastGun = hideGun; }
        VID_iOS_XR3_BeginEye(0, sep, conv);
        Qcommon_Frame();
        VID_iOS_XR3_BeginEye(1, sep, conv);
        SCR_UpdateScreen();
        VID_iOS_XR3_EndFrame();
    } else
#endif
    Qcommon_Frame();
    double f1 = self.benchmark ? CACurrentMediaTime() : 0;
    [self.glView updateTouchUI];
    [self driveAttract];
    [self updateFpsOverlay];
    Q2_VR_Tick();   // black box: ~1 Hz coalesced write (a no-op on every other frame)
    if (self.benchmark) [self recordBenchFrame:(f1 - f0) tick:(CACurrentMediaTime() - t0)];
    if (self.shots > 0) {   // [Phase 2] periodic artifact capture (demo or gameplay, not menu/cin)
        static int fc = 0;
        if (VID_iOS_PassiveState() != 2 && !VID_iOS_MenuActive() && ++fc >= 300) { fc = 0;
            VID_iOS_Command("screenshotpng"); self.shots--;
        }
    }
    static int lastFps = -1; int fps = VID_iOS_DisplayFps();
    if (fps != lastFps) { lastFps = fps; [self applyRefreshRate]; }   // live refresh-rate change
}

// [Phase 3] On-device frame-time profiler. Collects Qcommon_Frame() (engine work) and full
// tick (engine + touch-UI overlay) durations over a demo, then logs percentiles once. Enabled
// by the `-benchmark` launch arg only, so the shipping app is untouched. Charter method:
// measure before optimizing; one change, one measurement, recorded in MEASUREMENTS.md.
- (void)recordBenchFrame:(double)frameSec tick:(double)tickSec {
    static double frameMs[4000], tickMs[4000];
    static int n = 0, warm = 0;
    if (warm < 120) { warm++; return; }        // skip warm-up frames (load spikes)
    if (n >= 4000) return;
    frameMs[n] = frameSec * 1000.0; tickMs[n] = tickSec * 1000.0; n++;
    if (n < 4000) return;
    // sort copies for percentiles
    static double a[4000], b[4000];
    memcpy(a, frameMs, sizeof(a)); memcpy(b, tickMs, sizeof(b));
    qsort(a, 4000, sizeof(double), cmp_double);
    qsort(b, 4000, sizeof(double), cmp_double);
    double fmean = 0, tmean = 0; for (int i = 0; i < 4000; i++) { fmean += frameMs[i]; tmean += tickMs[i]; }
    fmean /= 4000; tmean /= 4000;
    VID_iOS_Command([NSString stringWithFormat:
        @"echo BENCH frame_ms mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f | tick_ms mean=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f | overlay_p95=%.2f",
        fmean, a[2000], a[3800], a[3960], a[3999],
        tmean, b[2000], b[3800], b[3960], b[3999], b[3800] - a[3800]].UTF8String);
    self.benchmark = NO;   // one-shot
}

// On-screen FPS counter (ios_fps): upstream has none, so we measure the display-link
// cadence app-side and draw a small top-left label. Smoothed; text updated ~8×/sec.
- (void)updateFpsOverlay {
    if (!VID_iOS_ShowFps() || VID_iOS_MenuActive()) {   // hide in menus (avoids the BACK pill)
        if (self.fpsLabel) self.fpsLabel.hidden = YES; self.fpsPrev = 0; return;
    }
    if (!self.fpsLabel) {
        UILabel *l = [UILabel new];
        l.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightBold];
        l.textColor = UIColor.whiteColor;                          // white number
        l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        l.textAlignment = NSTextAlignmentCenter; l.userInteractionEnabled = NO;
        l.layer.cornerRadius = 3; l.clipsToBounds = YES;
        [self.glView addSubview:l]; self.fpsLabel = l;
    }
    self.fpsLabel.hidden = NO;
    double now = self.link.timestamp;
    if (self.fpsPrev > 0) {
        double dt = now - self.fpsPrev;
        if (dt > 0) { double inst = 1.0 / dt; self.fpsSmooth = self.fpsSmooth > 0 ? self.fpsSmooth * 0.9 + inst * 0.1 : inst; }
    }
    self.fpsPrev = now;
    static int fc = 0;
    if (++fc >= 8) { fc = 0;
        self.fpsLabel.text = [NSString stringWithFormat:@"%d", (int)(self.fpsSmooth + 0.5)];  // number only
        [self.fpsLabel sizeToFit];
        UIEdgeInsets si = self.glView.safeAreaInsets;
        CGSize sz = self.fpsLabel.bounds.size;
        CGFloat w = sz.width + 6, h = sz.height + 2;               // tight box, ~3px side padding
        CGFloat x = self.glView.bounds.size.width - w - 24;        // top-right, small fixed margin
        self.fpsLabel.frame = CGRectMake(x, MAX(si.top, 4), w, h);
    }
}

- (void)applicationDidBecomeActive:(UIApplication *)app {
    if (!self.engineStarted) return;
    NSString *pl = [NSUserDefaults.standardUserDefaults stringForKey:@"q2_pending_launch"];   // warm intent launch
    if (pl) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"q2_pending_launch"];
        self.attract = NO;
        VID_iOS_Command([pl isEqualToString:@"menu"] ? "pushmenu main" : [NSString stringWithFormat:@"game %@", pl].UTF8String);
    }
    CL_Activate(ACT_ACTIVATED);
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_SetAppBackgrounded(0);   // [R21] VR-only: the glue that owns this flag is not linked on iOS
#endif
    Q2_VR_MarkRunning(1);   // [R14b] foreground again — re-arm the unclean-exit marker
}
- (void)applicationWillResignActive:(UIApplication *)app { if (self.engineStarted) CL_Activate(ACT_MINIMIZED); }
- (void)applicationDidEnterBackground:(UIApplication *)app  {
    // Persist settings (archived cvars + bindings) — iOS kills backgrounded apps, so the
    // engine's own write-on-quit (CL_Shutdown → CL_WriteConfig) never runs. `writeconfig_boot`
    // (overlay 0026) is that same writer on demand, so this writes the file the engine execs
    // at boot. It used to be `writeconfig q2reproconfig.cfg`, which writes a *named saved
    // config* under configs/ that nothing has ever exec'd — see Q-VR7.
    if (self.engineStarted) VID_iOS_Command("writeconfig_boot");
    // [R14b] A clean background is a clean shutdown as far as iOS is concerned — the system
    // may kill us from here at any time and that is expected, so disarm rather than cry wolf.
    Q2_VR_MarkRunning(0);
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_SetAppBackgrounded(1);   // [R21] the VR pacing repair must not re-activate audio from here
#endif
    q2_link_set(self, YES, "didEnterBackground");
}
- (void)applicationWillEnterForeground:(UIApplication *)app {
#if defined(Q2_XR_UI) && Q2_XR_UI
    Q2_VR_SetAppBackgrounded(0);   // [R21]
#endif
    q2_link_set(self, NO, "willEnterForeground");
}

@end

#if defined(Q2_XR_UI) && Q2_XR_UI
// ==================== SwiftUI hosting (merged visionOS 2D+3D app) ====================
// The merged app's entry is a SwiftUI @main (required to declare the stereoscopic
// ImmersiveSpace), so UIApplicationMain never runs and AppDelegate is not the UIApplication
// delegate — it lives on as the engine controller singleton, created by the hosted game VC.

static AppDelegate *q2_controller;
AppDelegate *Q2_SharedController(void) {
    if (!q2_controller) q2_controller = [AppDelegate new];
    return q2_controller;
}

// Build the game view controller for the SwiftUI WindowGroup. Same stack as
// bringUpGameInWindow minus the window-level operations (SwiftUI owns the window).
UIViewController *Q2_MakeGameViewController(void) {
    AppDelegate *app = Q2_SharedController();
    GameVC *vc = [GameVC new];
    CGFloat scale = 2.0;   // visionOS windows render @2x
    GLView *gl = [[GLView alloc] initWithFrame:CGRectMake(0, 0, 1280, 720)];
    gl.contentScaleFactor = scale;
    gl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    gl.multipleTouchEnabled = YES;
    vc.view = gl;
    g_touchView = gl;   // console seams (touchedit / q2_faketouch) reach the editor through this
    if (@available(visionOS 2.0, *)) {   // claim the pad from gaze-pinch (see bringUpGameInWindow)
        GCEventInteraction *padIntent = [[GCEventInteraction alloc] init];
        padIntent.handledEventTypes = GCUIEventTypeGamepad;
        [gl addInteraction:padIntent];
    }
    [vc installConsole];
    app.gameVC = vc;
    app.glView = gl;
    [gl layoutIfNeeded];
    gl.layer.contentsScale = scale;
    VID_iOS_SetLayer((__bridge void *)gl.layer);
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    if ([app hasGameData]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [app startEngine]; });
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [app presentImporter]; });
    }
    return vc;
}

// Scene-phase forwarding from the SwiftUI shell. The classic builds' SceneDelegate
// forwarded scene activation to the AppDelegate handlers, whose CL_Activate(ACT_ACTIVATED)
// reactivates the AVAudioSession + restarts the CoreAudio unit; the merged SwiftUI app
// compiled that out, so closing the window (app suspends, audio unit stops) and reopening
// left the game silent until relaunch. active: 1 = scene active, 0 = backgrounded.
void Q2_XR3_ScenePhase(int active) {
    AppDelegate *app = Q2_SharedController();
    if (!app.engineStarted) return;
    if (active) {
        q2_link_set(app, NO, "scenephase active");
        CL_Activate(ACT_ACTIVATED);       // → S_Activate → session setActive + AudioOutputUnitStart
        Q2_VR_MarkRunning(1);             // [R14b] re-arm the unclean-exit marker
    } else {
        VID_iOS_Command("writeconfig_boot");   // iOS/visionOS kill backgrounded apps
        Q2_VR_MarkRunning(0);             // [R14b] a clean background disarms it
        CL_Activate(ACT_MINIMIZED);
        q2_link_set(app, YES, "scenephase background");
    }
}

// 3D entry/exit, called from the SwiftUI shell AROUND openImmersiveSpace/dismiss.
// Order is load-bearing (vkQuake): the engine must stop touching the window surface
// BEFORE the space opens, and only return to it AFTER the space is dismissed.
void Q2_XR3_EngineEnter3D(void) { VID_iOS_XR3_SetMode(1); Q2_VR_SetMode(1); }
void Q2_XR3_EngineExit3D(void)  { VID_iOS_XR3_SetMode(0); Q2_VR_SetMode(0); }

// ---- VR entry/exit ------------------------------------------------------------------
// Frame ownership moves BEFORE the space opens. Under .full immersion visionOS stops
// ticking the hidden 2D window's display link, so an engine still driven by that link
// freezes on the entry frame: the 2D window stops, VR shows one frame forever, and audio
// keeps playing because nothing pumps the mixer. Pausing the link is therefore not an
// optimisation, it is the acknowledgement that the system has already stopped it.
//
// Everything here runs on the main thread while main still owns the ANGLE context; the
// context handover is the last step, inside Q2_VR_StartEngineThread.
void Q2_XR3_EngineEnterVR(void)
{
    AppDelegate *app = Q2_SharedController();
    Q2_VR_ResetMainTicksInVR();          // [R16] the counter is per VR SESSION
    q2_link_set(app, YES, "enter VR");
    // MSAA off and the render scale fixed for the duration: a multisampled or rescaled
    // depth buffer is not a valid single-sample depth snapshot, and the compositor
    // reprojects against exactly that snapshot. gl_multisamples already defaults to 0 —
    // this is the assertion, not the change.
    // Every archived cvar VR takes away from the player goes through the STASH, not through
    // a bare `set`: gl_shadows is CVAR_ARCHIVE, and a crash or a swipe-kill inside VR would
    // otherwise write "shadows off" into their config permanently, with no way for them to
    // know why. The stash is the list; msaa off, viewsize 100 and prediction on are in it.
    Q2_VR_StashCvars();
    VID_iOS_XR3_SetVRDepth(1);          // per-eye Depth32Float instead of the shared RB
    VID_iOS_XR3_SetUIRedirect(1);       // HUD/menus/console onto their own texture (D6)
    VID_iOS_XR3_SetMode(1);             // engine renders the eye FBOs, not the window
    Q2_VR_SetMode(2);
    // A touch in flight when the space opened would otherwise stay latched forever: the
    // window is parked and curtained, so no touchesEnded is ever coming for it.
    VID_iOS_AnalogMove(0, 0);
    VID_iOS_LookAnalog(0, 0);
    Q2_VR_PadClear();
    Q2_VR_StartEngineThread();
    [app startVRPadTimer];
}

int  Q2_XR3_EngineVRStopRequest(void) { Q2_VR_RequestEngineStop(); return 1; }
int  Q2_XR3_EngineVRStopped(void)     { return !Q2_VR_EngineThreadRunning(); }

// Idempotent and unconditional. It is called from the ordinary exit, from the rollback of
// a failed entry, and from the Digital Crown belt — a finalize that only runs on a state
// TRANSITION does not run on the path that needs it most.
void Q2_XR3_EngineExitVR(void)
{
    [Q2_SharedController() stopVRPadTimer];
    Q2_VR_FinishEngineStop();           // context back to main, funnel off, queue drained
    VID_iOS_XR3_SetVRDepth(0);
    VID_iOS_XR3_SetUIRedirect(0);
    VID_iOS_XR3_SetMode(0);
    Q2_VR_SetMode(0);
    // The player gets their cvars back. Idempotent and unconditional, like the rest of this
    // finalize: it is also called from a failed entry's rollback and from the Crown belt, and
    // a restore that only ran on a clean exit would not run on the path that needs it.
    Q2_VR_RestoreCvars();
    Q2_VR_PadClear();
    // Last: hand the frame back to main. Normally the engine thread has already stopped
    // (Q2_VR_FinishEngineStop above) and the funnel allows this. But the Swift side's thread
    // stop is a BOUNDED 2 s poll that finalizes anyway on timeout — and then the funnel would
    // REFUSE this unpause, leaving the link paused forever with nothing left to unpause it: a
    // 2D app frozen after Exit VR (R16 review finding). So this one site bypasses the refusal.
    // It is still safe: `tick`'s own guard keeps refusing to DRIVE the engine while the thread
    // runs, so a late thread cannot be double-driven — and the moment it exits, the ticking
    // link resumes the 2D app on its own instead of never.
    {
        AppDelegate *app = Q2_SharedController();
        const int late = Q2_VR_EngineThreadRunning();
        if (late) q2_link_log(app, "LINK exit VR finalize with the VR engine thread STILL RUNNING - forcing the unpause; tick stays guarded until it exits");
        atomic_store(&q2_link_reason, "exit VR finalize");
        if (app.link) {
            app.link.paused = NO;
            q2_link_log(app, late ? "LINK paused=0 reason=exit VR finalize (forced)"
                                  : "LINK paused=0 reason=exit VR finalize");
        }
    }
}

// The GAME window's size — never UIApplication.keyWindow. Tapping the ornament pill
// ("3D"/gear) makes the pill's ~182x68 host window KEY at exactly the moment the entry
// capture runs, which poisoned the restore size on device for weeks (sim entries are
// env-driven, never tap, so the sim could not reproduce it). quake3e reads its game
// VC's window for the same reason.
CGSize Q2_XR3_GameWindowSize(void) {
    UIWindow *w = Q2_SharedController().gameVC.view.window;
    return w ? w.bounds.size : CGSizeZero;
}

// Window-geometry diagnostics from the SwiftUI shell, routed into the engine console so
// they land in logs/console.log (the one channel the user can pull from the device).
// Message must be console-safe: no quotes/semicolons.
void Q2_XR3_Log(const char *msg) {
    AppDelegate *app = Q2_SharedController();
    if (!app.engineStarted) { NSLog(@"[q2repro] %s", msg); return; }
    // NOT the `echo` command any more: its parser splits on ';' and breaks on '"', which
    // made those two characters unusable in every diagnostic line the shell emits. Q2_VR_Log
    // goes to Com_Printf directly (so console.log and the tcp/8770 bridge both carry it) and
    // to the black box's rolling tail, sanitising as it goes.
    extern void Q2_VR_Log(const char *msg);
    Q2_VR_Log(msg);
}
#else
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
#endif // Q2_XR_UI
