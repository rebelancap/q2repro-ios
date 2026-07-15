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
extern void CL_SetAnalogMove(float forward, float side);   // analog move axis [-1,1]
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
extern void VID_iOS_LookDelta(float yaw, float pitch);    // absolute degrees (touch/gyro)
extern void VID_iOS_LookAnalog(float yaw, float pitch);   // stick rate (pre-scaled)
#if defined(Q2_XR_UI) && Q2_XR_UI
// Merged 2D+3D (vid_angle.m stereo mode + client/screen.c). In 3D the tick renders the
// complete frame twice per engine step — left/right eye, same game time.
extern int  VID_iOS_XR3_Active(void);
extern void VID_iOS_XR3_SetMode(int on);
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
@end
@implementation GLView {
    UITouch *_moveTouch, *_lookTouch;
    CGPoint _moveOrigin, _lookLast;
    UIView *_stickBase, *_stickKnob;   // visual floating joystick
    NSMutableArray<NSDictionary *> *_btns;   // touch buttons: btn, ux, uy, sz, key/cmd, hap
    UIButton *_backBtn;                // menu-only BACK (arrow)
    UIView *_touchCursor;             // menu-only "where you tapped" crosshair ring+dot
    UIButton *_wheelBtn;              // context button: wheel (Quake 2) / WPN (Action)
    int _wheelIsAction;               // -1 unknown; tracks _wheelBtn's current mode
    id _haptic;   // UIImpactFeedbackGenerator on iOS; nil on visionOS (no haptics)
    CGSize _lastDrawPx;   // last drawable pixel size, to fire VID_iOS_Resize only on real change
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

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
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
    if (_moveTouch && ![active containsObject:_moveTouch]) { _moveTouch = nil; CL_SetAnalogMove(0,0); [self hideStick]; }

    if (GCController.controllers.count > 0) return;   // gamepad connected → ignore touch move/look
    CGFloat midx = self.bounds.size.width / 2;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        if (p.x < midx && !_moveTouch)      { _moveTouch = t; _moveOrigin = p; [self showStickAt:p]; }
        else if (p.x >= midx && !_lookTouch) { _lookTouch = t; _lookLast = p; }
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e {
    if (VID_iOS_MenuActive()) { [self menuTouch:touches.anyObject]; return; }
    CGFloat midx = self.bounds.size.width / 2;
    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        // Re-acquire look if our reference was lost while the finger is still down.
        if (t != _moveTouch && t != _lookTouch && !_lookTouch && p.x >= midx) {
            _lookTouch = t; _lookLast = p;   // re-anchor; no delta this frame
        }
        if (t == _moveTouch) {
            CGFloat dx = p.x - _moveOrigin.x, dy = p.y - _moveOrigin.y;
            CGFloat d = hypot(dx, dy);
            if (d > STICK_RADIUS) { dx *= STICK_RADIUS/d; dy *= STICK_RADIUS/d; }
            CL_SetAnalogMove((float)(-dy / STICK_RADIUS), (float)(dx / STICK_RADIUS));  // analog: up=forward
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
    if (VID_iOS_MenuActive()) { VID_iOS_MenuKey(IOS_MENU_CLICK, NO); return; }
    for (UITouch *t in touches) {
        if (t == _moveTouch) {
            _moveTouch = nil;
            CL_SetAnalogMove(0, 0);
            [self hideStick];
        } else if (t == _lookTouch) {
            _lookTouch = nil;
        }
    }
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { [self endTouches:touches]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)e { [self endTouches:touches]; }

// ---- On-screen touch buttons (Fable-style unit-anchored layout) -------------
// Buttons send KEX virtual keys so they share binds with the controller. Hold
// buttons (WHL/JMP/FIRE/CRO) = key down/up; tap buttons (MENU/SCR/BACK) = command.
// label: a plain string → bold text; a string prefixed "sf:" → SF Symbol image (scaled
// to fill the round button). sym pt sizing is derived from the button size in layout.
- (UIButton *)makePad:(NSString *)label {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    if ([label hasPrefix:@"sf:"]) {
        UIImage *img = [UIImage systemImageNamed:[label substringFromIndex:3]];
        [b setImage:img forState:UIControlStateNormal];
        b.adjustsImageWhenHighlighted = NO;
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
    // Hold button that sends a raw command on down/up (works in BOTH the rerelease AND the
    // classic Action game — unlike KEX virtual keys, which only resolve via rerelease binds,
    // so fire/jump/crouch were dead in Action).
    void (^cmdhold)(NSString *, CGFloat, CGFloat, CGFloat, SEL, SEL) = ^(NSString *l, CGFloat ux, CGFloat uy, CGFloat sz, SEL down, SEL up) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:down forControlEvents:UIControlEventTouchDown];
        [b addTarget:self action:up forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
        [_btns addObject:@{@"b":b, @"ux":@(ux), @"uy":@(uy), @"sz":@(sz)}];
    };
    void (^tap)(NSString *, CGFloat, CGFloat, CGFloat, SEL) = ^(NSString *l, CGFloat ux, CGFloat uy, CGFloat sz, SEL s) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
        [_btns addObject:@{@"b":b, @"ux":@(ux), @"uy":@(uy), @"sz":@(sz)}];
    };
    // EXACT Fable layout (ios/shell/Q2TouchControls.m): unit fractions of the safe-area
    // rect, sizes in points. The top-right action button is context-sensitive: the weapon
    // WHEEL (hold) in Quake II, or WPN next-weapon (tap) in Action — set in updateTouchUI.
    _wheelBtn = [self makePad:@""];
    [_wheelBtn addTarget:self action:@selector(wheelDown:) forControlEvents:UIControlEventTouchDown];
    [_wheelBtn addTarget:self action:@selector(wheelDrag:forEvent:) forControlEvents:UIControlEventTouchDragInside|UIControlEventTouchDragOutside];
    [_wheelBtn addTarget:self action:@selector(wheelUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    _wheelIsAction = -1;
    [_btns addObject:@{@"b":_wheelBtn, @"ux":@(0.905), @"uy":@(0.30), @"sz":@(56)}];
    // Item/powerup wheel (Quake II only), to the LEFT of the weapon wheel. Hold to open, drag to
    // select, release to pick — renders centred on this button (+wheel2 / -wheel2).
    UIButton *itemBtn = [self makePad:@"sf:bag.fill"];
    [itemBtn addTarget:self action:@selector(itemDown:) forControlEvents:UIControlEventTouchDown];
    [itemBtn addTarget:self action:@selector(wheelDrag:forEvent:) forControlEvents:UIControlEventTouchDragInside|UIControlEventTouchDragOutside];
    [itemBtn addTarget:self action:@selector(itemUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    [_btns addObject:@{@"b":itemBtn, @"ux":@(0.825), @"uy":@(0.30), @"sz":@(52), @"noaction":@(1)}];
    cmdhold(@"JMP",  0.955, 0.45, 60, @selector(jumpDown), @selector(jumpUp));
    cmdhold(@"FIRE", 0.895, 0.72, 76, @selector(fireCmdDown), @selector(fireCmdUp));
    cmdhold(@"CRO",  0.80,  0.96, 52, @selector(crouchDown), @selector(crouchUp));
    tap(@"sf:line.3.horizontal", 0.97,  0.09, 40, @selector(padMenu));     // menu (hamburger)
    tap(@"sf:list.number",       0.905, 0.09, 44, @selector(padScores));   // objectives / scoreboard

    // Action-only in-game menu nav (join team / loadout are game-drawn LAYOUT_MENU menus,
    // navigated by invprev/invnext/invuse — not clickable). Shown only while Action is active.
    void (^actbtn)(NSString *, CGFloat, CGFloat, CGFloat, SEL) = ^(NSString *l, CGFloat ux, CGFloat uy, CGFloat sz, SEL s) {
        UIButton *b = [self makePad:l];
        [b addTarget:self action:s forControlEvents:UIControlEventTouchUpInside];
        [_btns addObject:@{@"b":b, @"ux":@(ux), @"uy":@(uy), @"sz":@(sz), @"act":@(1)}];
    };
    actbtn(@"sf:chevron.up",   0.055, 0.30, 44, @selector(actInvPrev));
    actbtn(@"sf:chevron.down", 0.055, 0.52, 44, @selector(actInvNext));
    actbtn(@"OK",              0.055, 0.74, 44, @selector(actInvUse));
    // Action-only gameplay buttons ("actgame"): shown in Action when no game menu is up.
    // Top-left: (re)open the team/loadout menu. Right of FIRE: sniper zoom (cmd lens in cycles 1/2/4/6×).
    UIButton *recall = [self makePad:@"sf:person.2.fill"];
    [recall addTarget:self action:@selector(actMenuRecall) forControlEvents:UIControlEventTouchUpInside];
    [_btns addObject:@{@"b":recall, @"ux":@(0.055), @"uy":@(0.09), @"sz":@(44), @"actgame":@(1)}];
    UIButton *zoom = [self makePad:@"Z+"];
    [zoom addTarget:self action:@selector(actZoom) forControlEvents:UIControlEventTouchUpInside];
    [_btns addObject:@{@"b":zoom, @"ux":@(0.985), @"uy":@(0.60), @"sz":@(52), @"actgame":@(1)}];

    _backBtn = [self makePad:@"sf:arrowshape.turn.up.backward.fill"];   // menu-only back arrow
    [_backBtn addTarget:self action:@selector(padBack) forControlEvents:UIControlEventTouchUpInside];
    _backBtn.hidden = YES;

    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerBack:)];
    g.numberOfTouchesRequired = 2; g.cancelsTouchesInView = NO;
    [self addGestureRecognizer:g];
}
// Scale an SF-Symbol button's glyph to fill its round frame.
- (void)sizeSymbol:(UIButton *)b to:(CGFloat)sz ratio:(CGFloat)ratio weight:(UIImageSymbolWeight)w {
    if (!b.currentImage) return;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:sz*ratio weight:w];
    [b setPreferredSymbolConfiguration:cfg forImageInState:UIControlStateNormal];
}
- (void)padDown:(UIButton *)b {
    VID_iOS_KeyEvent((int)b.tag, YES);
    if (b.tag == K_RIGHT_TRIGGER && VID_iOS_Haptics()) Q2_HAPTIC(_haptic);
}
- (void)padUp:(UIButton *)b { VID_iOS_KeyEvent((int)b.tag, NO); }
- (void)padMenu   { VID_iOS_ToggleMenu(); }
- (void)padScores { VID_iOS_Command("cmd help"); }   // help computer / objectives (the numbered list)
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

// Called each frame: position + scale/opacity/lefty + hide when a menu is up.
- (void)updateTouchUI {
    [self ensureButtons];
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    CGFloat scale = VID_iOS_TouchScale(), alpha = VID_iOS_TouchAlpha();
    BOOL lefty = VID_iOS_TouchLefty(), inMenu = VID_iOS_MenuActive();
    BOOL passive = VID_iOS_PassiveState() != 0;         // demo / cinematic playing
    BOOL pad = GCController.controllers.count > 0;      // a gamepad is connected
    BOOL hideGame = inMenu || passive || pad;           // controls only during live touch play
    if (pad) VID_iOS_SetWheelAnchor(-1, -1);            // controller → wheel renders at default centre
    BOOL layoutUp = VID_iOS_LayoutActive();             // Action join/loadout menu on screen
    // Context button: thin weapon-wheel glyph in Quake II, "WPN" text in Action. Only reskin
    // on a game change (avoids per-frame churn).
    int isAct = VID_iOS_IsAction() ? 1 : 0;
    if (isAct != _wheelIsAction) {
        _wheelIsAction = isAct;
        if (isAct) {
            [_wheelBtn setImage:nil forState:UIControlStateNormal];
            [_wheelBtn setTitle:@"WPN" forState:UIControlStateNormal];
            _wheelBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        } else {
            [_wheelBtn setTitle:nil forState:UIControlStateNormal];
            [_wheelBtn setImage:[UIImage systemImageNamed:@"circle.hexagongrid"] forState:UIControlStateNormal];
        }
    }
    for (NSDictionary *d in _btns) {
        UIButton *b = d[@"b"];
        CGFloat ux = [d[@"ux"] doubleValue], uy = [d[@"uy"] doubleValue], sz = [d[@"sz"] doubleValue] * scale;
        if (lefty) ux = 1.0 - ux;
        b.bounds = CGRectMake(0, 0, sz, sz);
        b.center = CGPointMake(r.origin.x + ux * r.size.width, r.origin.y + uy * r.size.height);
        b.layer.cornerRadius = sz / 2;
        UIImageSymbolWeight w = (b == _wheelBtn) ? UIImageSymbolWeightLight : UIImageSymbolWeightSemibold;  // thinner wheel
        [self sizeSymbol:b to:sz ratio:0.5 weight:w];
        b.alpha = alpha * 0.85;
        if ([d[@"actgame"] boolValue])
            b.hidden = hideGame || !isAct || layoutUp;   // Action gameplay, only while no game menu is up
        else if ([d[@"noaction"] boolValue])
            b.hidden = hideGame || isAct;                // item wheel: Quake II only (Action has no wheels)
        else
            // Action menu-nav buttons appear only while Action is active AND a game layout/menu is up.
            b.hidden = hideGame || ([d[@"act"] boolValue] && !(isAct && layoutUp));
    }
    if (hideGame) [self hideStick];                     // no floating stick during demo/menu
    CGFloat bsz = 46 * scale;                           // smaller back button
    _backBtn.bounds = CGRectMake(0, 0, bsz, bsz);
    _backBtn.center = CGPointMake(r.origin.x + bsz*0.65, r.origin.y + bsz*0.65);
    _backBtn.layer.cornerRadius = bsz / 2;
    [self sizeSymbol:_backBtn to:bsz ratio:0.4 weight:UIImageSymbolWeightRegular];   // lighter/smaller arrow
    _backBtn.alpha = alpha * 0.9;
    _backBtn.hidden = !inMenu;
    if (!inMenu && _touchCursor) _touchCursor.hidden = YES;   // cursor is menu-only
}
@end

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
@end

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
- (void)installMenuResource:(NSString *)resource intoGame:(NSString *)gamedir {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:gamedir];
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
        NSLog(@"[q2repro] installed %@/q2repro.menu (%@)", gamedir, bv);
    }
}
- (void)installMenu {
    [self installMenuResource:@"q2repro" intoGame:@"baseq2"];   // base menu
    [self installMenuResource:@"action"  intoGame:@"action"];   // Action Quake theming (ships in IPA)
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
- (void)generateModsMenu {
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
    [m writeToFile:[docs stringByAppendingPathComponent:@"baseq2/q2repro_mods.menu"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[q2repro] mods menu: %lu mod(s)%@", (unsigned long)mods.count, allow ? @" (allowlist)" : @"");
}

- (void)startEngine {
    if (self.engineStarted) return;
    self.engineStarted = YES;
    [self installMenu];
    [self generateModsMenu];

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
    // Default pad layout for vanilla-pak installs (config.cfg already exec'd, so user
    // rebinds win). Needed at boot — not just pad-connect — because the TOUCH weapon
    // wheel resolves through the right_shoulder bind too.
    VID_iOS_EnsureGamepadBinds();
    // A stray archived gl_modulate_entities=3 (engine default 1) lit entity models at
    // gl_modulate(2)×3 = 6× vs the world's 2× — guns/enemies/items blew out while the world
    // looked fine. Reset to default so models match world brightness.
    VID_iOS_Command("set gl_modulate_entities 1");
    NSLog(@"[q2repro] engine initialized; starting display link");

    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [self applyRefreshRate];
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

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
    GCExtendedGamepad *gp = GCController.controllers.firstObject.extendedGamepad;
    if (!gp) { hadPad = NO; return; }

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
        static BOOL pmenu = NO; BOOL c = gp.buttonMenu.isPressed;
        if (c && !pmenu) VID_iOS_ToggleMenu();
        pmenu = c;
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
    if (fabsf(lx) > 0.15f || fabsf(ly) > 0.15f) { CL_SetAnalogMove(ly, lx); moving = YES; }
    else if (moving) { CL_SetAnalogMove(0, 0); moving = NO; }

    float rx = gp.rightThumbstick.xAxis.value, ry = gp.rightThumbstick.yAxis.value;
    float csx = VID_iOS_SensX() / 3.0f, csy = VID_iOS_SensY() / 3.0f;   // neutral 3 = 1.0×
    float iy = VID_iOS_InvertY() ? -1.0f : 1.0f;
    if (fabsf(rx) < 0.12f) rx = 0;   // deadzone
    if (fabsf(ry) < 0.12f) ry = 0;
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
}
- (void)applicationWillResignActive:(UIApplication *)app { if (self.engineStarted) CL_Activate(ACT_MINIMIZED); }
- (void)applicationDidEnterBackground:(UIApplication *)app  {
    // Persist settings (archived cvars + bindings) — iOS kills backgrounded apps, so
    // the engine's write-on-quit never runs. Writes q2reproconfig.cfg (read at boot).
    if (self.engineStarted) VID_iOS_Command("writeconfig q2reproconfig.cfg");
    self.link.paused = YES;
}
- (void)applicationWillEnterForeground:(UIApplication *)app { self.link.paused = NO; }

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

// 3D entry/exit, called from the SwiftUI shell AROUND openImmersiveSpace/dismiss.
// Order is load-bearing (vkQuake): the engine must stop touching the window surface
// BEFORE the space opens, and only return to it AFTER the space is dismissed.
void Q2_XR3_EngineEnter3D(void) { VID_iOS_XR3_SetMode(1); }
void Q2_XR3_EngineExit3D(void)  { VID_iOS_XR3_SetMode(0); }
#else
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class])); }
}
#endif // Q2_XR_UI
