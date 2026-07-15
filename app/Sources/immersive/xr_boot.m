// xr_boot.m — boots the q2repro engine for the immersive (3D) variant and drives frames.
// Called from the Compositor Services render loop (ImmersiveApp.swift). Boots the game data the
// user copied into the app's Documents (vanilla baseq2 → classic engine, like every VR Quake II;
// a rerelease set → rerelease engine) and starts a map so there is a 3D scene to view in stereo.
// Runs on the render thread, where the ANGLE context is current.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include "shared/shared.h"
#include "common/common.h"
#include "common/cmd.h"
#include "client/keys.h"                       // Key_GetDest / KEY_CONSOLE / K_*_BUTTON

extern void Qcommon_Init(int argc, char **argv);
extern void Qcommon_Frame(void);
extern void VID_iOS_RegisterCvars(void);       // ios_bridge.m
extern void VID_iOS_Command(const char *cmd);  // xr_render.m
extern void SCR_UpdateScreen(void);            // client/screen.c — re-render current state
extern void V_SetStereoOffset(float offset);   // overlay 0016 — per-eye view shift
extern void V_SetStereoConvergence(float c);   // overlay 0020 — convergence ("crosshair") distance
extern void R_BeginFrame(void);                // refresh — begin/render/end for the light 2nd eye
extern void R_EndFrame(void);
extern void V_RenderView(void);                // client/view.c — 3D scene only (no 2D/HUD/console)
extern bool V_FrameRendered(bool clear);       // overlay 0018 — did V_RenderView run this frame?
extern void Con_Close(bool force);             // client/console.c — retract the pull-down console
extern void CL_Activate(int active);           // client/main.c — activate the client (2=ACT_ACTIVATED)
extern void CL_SetAnalogMove(float forward, float side);  // client/input.c (overlay) — analog move
extern void VID_iOS_LookAnalog(float yaw, float pitch);   // ios_bridge.m — stick-rate look
extern void VID_iOS_KeyEvent(int keynum, bool down);      // ios_bridge.m — key through the bind system

static int s_booted;

// Poll the game controller in the immersive loop and route it to the engine, mirroring the 2D
// app's pollController (main.m): left stick = analog move, right stick = rate look, buttons go
// through the engine BIND system as KEX virtual keys so the rerelease default.cfg pad layout
// (weapon wheel on the shoulder, etc.) works unmodified. Called each frame on the render thread,
// where the engine runs. (The 2D app's gaze-pinch problem is a SHARED-SPACE behavior; a full
// ImmersiveSpace delivers controller input to GCController, so no GCEventInteraction view is
// needed here — a full-immersion app has no gaze target to steal the presses.)
void Q2_XR_PollInput(void) {
    if (!s_booted) return;
    GCExtendedGamepad *gp = GCController.controllers.firstObject.extendedGamepad;
    if (!gp) return;

    // Left stick → analog movement (deadzone 0.15).
    float lx = gp.leftThumbstick.xAxis.value, ly = gp.leftThumbstick.yAxis.value;
    if (fabsf(lx) < 0.15f) lx = 0;
    if (fabsf(ly) < 0.15f) ly = 0;
    CL_SetAnalogMove(ly, lx);

    // Right stick → rate look (deadzone 0.12). Turning the view is how you aim in the seated
    // stereo mode; the head pose adds the slight parallax. LOOK_RATE is a starting sensitivity.
    static const float LOOK_RATE = 2.0f;
    float rx = gp.rightThumbstick.xAxis.value, ry = gp.rightThumbstick.yAxis.value;
    if (fabsf(rx) < 0.12f) rx = 0;
    if (fabsf(ry) < 0.12f) ry = 0;
    VID_iOS_LookAnalog(rx * LOOK_RATE, ry * LOOK_RATE);

    // Buttons → engine bind system (edge-triggered).
    static bool st[16] = {0};
    #define GK(i, cur, key) do { bool c_ = (cur); if (c_ != st[i]) { VID_iOS_KeyEvent((key), c_); st[i] = c_; } } while (0)
    GK(0,  gp.buttonA.isPressed,          K_A_BUTTON);
    GK(1,  gp.buttonB.isPressed,          K_B_BUTTON);
    GK(2,  gp.buttonX.isPressed,          K_X_BUTTON);
    GK(3,  gp.buttonY.isPressed,          K_Y_BUTTON);
    GK(4,  gp.leftShoulder.isPressed,     K_LEFT_SHOULDER);
    GK(5,  gp.rightShoulder.isPressed,    K_RIGHT_SHOULDER);
    GK(6,  gp.leftTrigger.value  > 0.3f,  K_LEFT_TRIGGER);
    GK(7,  gp.rightTrigger.value > 0.3f,  K_RIGHT_TRIGGER);
    GK(8,  gp.dpad.up.isPressed,          K_DPAD_UP);
    GK(9,  gp.dpad.down.isPressed,        K_DPAD_DOWN);
    GK(10, gp.dpad.left.isPressed,        K_DPAD_LEFT);
    GK(11, gp.dpad.right.isPressed,       K_DPAD_RIGHT);
    if (@available(visionOS 1.0, *)) {
        GK(12, gp.leftThumbstickButton.isPressed,  K_LEFT_STICK);
        GK(13, gp.rightThumbstickButton.isPressed, K_RIGHT_STICK);
    }
    #undef GK
}

// Resolve the game data dir (mirrors main.m's basedir logic): a rerelease set
// (Documents/rerelease/baseq2 + Q2Game.kpf) → basedir=Documents/rerelease, com_rerelease 1;
// an original baseq2 in the Documents root → basedir=Documents, com_rerelease 0. homedir is
// always Documents (writable saves/config/logs). When NO data is found, drop a readme at the
// Documents root so the app APPEARS in the Files app ("On My Vision Pro") — Files hides an app
// whose Documents folder is empty, which is why the 3D app never showed a folder to drop data
// into (the 2D app shows because it writes its bundled menu into baseq2/ at boot). Returns true
// iff real game data is present.
static NSString *s_basedir, *s_homedir;
static int s_rerelease;

static bool xr_resolve_data(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"rerelease/baseq2/pak0.pak"]]) {
        // homedir = basedir (NOT Documents): Quake searches <homedir>/baseq2 BEFORE
        // <basedir>/baseq2, so a leftover vanilla Documents/baseq2 would SHADOW the rerelease
        // baseq2 for every same-named file (default.cfg, crosshair/weaponwheel pics, the
        // protocol-26 demos) — which is what made the crosshair look "vanilla", the pad binds
        // fall back to the 1997 default.cfg, and the console spam "couldn't load weaponwheel".
        // Pointing both at the rerelease set keeps Documents/baseq2 out of the path entirely.
        s_basedir = s_homedir = [docs stringByAppendingPathComponent:@"rerelease"]; s_rerelease = 1; return true;
    }
    if ([fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"baseq2/pak0.pak"]] ||
        [fm fileExistsAtPath:[docs stringByAppendingPathComponent:@"baseq2/pak0.PAK"]]) {
        s_basedir = s_homedir = docs; s_rerelease = 0; return true;
    }
    s_basedir = s_homedir = docs; s_rerelease = 0;
    NSString *readme = [docs stringByAppendingPathComponent:@"READ ME — add Quake II data.txt"];
    if (![fm fileExistsAtPath:readme]) {
        NSString *msg =
          @"q2repro 3D needs your Quake II game data.\n\n"
           "In the Files app, open:  On My Vision Pro > q2repro 3D\n"
           "and copy your game data into this folder — either:\n"
           "  - a \"baseq2\" folder (original Quake II .pak files), or\n"
           "  - the \"rerelease\" folder from the 2023 re-release.\n\n"
           "Tip: if the \"q2repro\" app already has your data, you can copy the\n"
           "folder straight across between the two apps inside the Files app.\n\n"
           "Then reopen q2repro 3D and tap Enter 3D.\n";
        [msg writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return false;
}

// Exposed to the SwiftUI launcher: true iff game data is present. Side effect: creates the
// Documents readme when data is absent, so the app becomes visible in Files and the user can
// drop data in. Safe to call repeatedly; never touches existing data.
bool Q2_XR_HasData(void) { return xr_resolve_data(); }

// Diagnostic for headless sim validation (the visionOS sim can't screenshot immersive content):
// is the pull-down console currently up? Surfaced in the launcher window's status line, which
// IS screenshot-able on the sim — so we can confirm the console-close fix without the headset.
int Q2_XR_ConsoleOpen(void) { return (Key_GetDest() & KEY_CONSOLE) ? 1 : 0; }

// Data mode for the launcher ("rerelease" / "vanilla" / "?" before boot) so the user can SEE
// which game data actually won — the whole point of the shadowing fix above.
const char *Q2_XR_DataMode(void) { return !s_booted ? "?" : (s_rerelease ? "rerelease" : "vanilla"); }

// Hide/show the weapon viewmodel. With convergence (overlay 0020) the gun fuses fine and pops
// out slightly — so it's SHOWN by default now; the toggle remains for comfort preference.
void Q2_XR_SetHideGun(int hide) { if (s_booted) VID_iOS_Command(hide ? "set cl_gun 0" : "set cl_gun 1"); }

// Stereo convergence distance C ("Crosshair Distance", world units): the depth that sits exactly
// ON the virtual screen (overlay 0020 skews each eye's projection to converge there). Without it
// zero-parallax is at infinity and near objects (the gun) have unfusable crossed disparity — the
// root cause of "the gun jumps between two locations" (binocular rivalry), per the vkQuake review.
void Q2_XR_SetConvergence(float c) { V_SetStereoConvergence(c); }

void Q2_XR_Boot(void) {
    if (s_booted) return;
    s_booted = 1;

    bool haveData = xr_resolve_data();
    const char *cbase = strdup(s_basedir.fileSystemRepresentation);
    const char *chome = strdup(s_homedir.fileSystemRepresentation);

    static char *argv[48]; int argc = 0;
    argv[argc++] = strdup("q2repro");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("logfile");       argv[argc++] = strdup("1");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("logfile_flush"); argv[argc++] = strdup("1");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("basedir");       argv[argc++] = strdup(cbase);
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("homedir");       argv[argc++] = strdup(chome);
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("com_rerelease"); argv[argc++] = strdup(s_rerelease ? "1" : "0");
    // Simplest render path for M1: no post-process FBOs (the world draws straight into our eye
    // framebuffer instead of FBO_SCENE + an upscale that was dropping the 3D view), and render
    // synchronously so every compositor frame gets a fresh engine frame (no black flashes).
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("gl_bloom");      argv[argc++] = strdup("0");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("gl_waterwarp");  argv[argc++] = strdup("0");
    argv[argc++] = strdup("+set"); argv[argc++] = strdup("cl_async");      argv[argc++] = strdup("0");
    // Start a map only when the data is actually present (else stay at the console; the launcher
    // shows the "add game data" instructions before you ever enter).
    if (haveData) { argv[argc++] = strdup("+map"); argv[argc++] = strdup("base1"); }
    argv[argc] = NULL;

    NSLog(@"[q2repro-xr] Qcommon_Init basedir=%s rerelease=%d data=%d", cbase, s_rerelease, haveData);
    Qcommon_Init(argc, argv);
    VID_iOS_RegisterCvars();
    // Match the 2D app's rerelease brightness fix (a stray archived gl_modulate_entities=3 blows
    // out entity models); harmless in vanilla.
    if (s_rerelease) VID_iOS_Command("set gl_modulate_entities 1");
    // Fully activate the client — the 2D shell does this after Qcommon_Init; the immersive shell
    // never did, which left the client half-activated (a likely reason the boot console clung on
    // device where it didn't on the sim).
    CL_Activate(2 /* ACT_ACTIVATED */);
    NSLog(@"[q2repro-xr] engine booted");
}

void Q2_XR_Frame(void) {
    if (!s_booted) return;
    Q2_XR_PollInput();       // feed controller input to the engine before it steps the sim
    V_FrameRendered(true);   // clear the world-rendered flag so it reflects THIS frame only
    Qcommon_Frame();
    // Force a clean in-game view once the map is live. Con_Close() self-guards on
    // cls.state == ca_active (it no-ops during the connect/load phase, where the console SHOULD
    // show progress), so calling it UNCONDITIONALLY every frame drops the boot console the instant
    // base1 is active and re-asserts it against the connect-phase Con_Popup — with no key_dest gate
    // and no fixed timer. (The earlier version gated on `Key_GetDest() & KEY_CONSOLE`; that closed
    // it on the sim but not the headset — likely the console was up via con height without that
    // key-dest bit — so the gate is gone. It also clears console/menu key focus via Con_Close's own
    // Key_SetDest, giving a clean game view.)
    Con_Close(true);
}

// Stereo: set the per-eye view offset, and re-render the current frame (no sim step) into the
// currently-bound eye framebuffer. The shell calls Q2_XR_Frame() for the first (left) eye — which
// steps the sim and renders — then Q2_XR_RenderView() for the right eye against the same state.
void Q2_XR_SetStereo(float offset) { V_SetStereoOffset(offset); }
// Right eye: re-draw the COMPLETE frame (world + HUD + crosshair + console/menus) from the same
// sim state — SCR_UpdateScreen draws current state without stepping the sim, and carries all the
// engine's own safety guards (no world → it draws the 2D screen; never the raw R_RenderFrame
// assert). Rendering the FULL frame in both eyes is the vkQuake shape: 2D elements land at
// identical pixels in both eyes = zero disparity = exactly on the panel plane. The previous
// V_RenderView-only right eye left the HUD/crosshair in ONE eye — a monocular overlay that
// shimmers and fights fusion right where the player stares.
int Q2_XR_RenderView(void) {
    if (!s_booted) return 0;
    SCR_UpdateScreen();
    return 1;
}
