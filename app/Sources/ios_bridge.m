// ios_bridge.m — small C bridge from the app's touch/controller input to the
// engine's menu (UI) input, so the q2pro menu is navigable on iOS. Pure C (no
// UIKit) so it can include engine headers directly, like the engine .c files.
// Always compiled in the app target; independent of the vid driver.
#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"                     // Cmd_AddCommand, Cmd_Argc/Argv
#include "system/system.h"
#include "client/keys.h"                    // keydest_t, KEY_MENU, Key_GetDest, K_* codes

extern void UI_MouseEvent(int x, int y);    // client/ui/ui.h (internal)
extern void Key_Event(unsigned key, bool down, unsigned time);  // keys.c (private decl)

// --- iOS settings cvars (CVAR_ARCHIVE → persist via q2reproconfig.cfg) ----------
// Registered after Qcommon_Init; read live by the touch/render layers. Mirrors the
// prior port's ios_* scheme so the in-menu "iOS settings" page drives real behavior.
static cvar_t *c_sens_x, *c_sens_y, *c_invert_y, *c_touch_scale, *c_touch_alpha,
              *c_touch_lefty, *c_haptics, *c_display_fps, *c_fps, *c_gyro;

// Audio settings (ios_audio.m). Registered LAZILY, not in VID_iOS_RegisterCvars:
// the CoreAudio driver reads the mode from inside S_Init — i.e. during
// Qcommon_Init, before RegisterCvars runs — because the session category has to
// be right before the driver's first setActive:YES (that is the only activation
// that can interrupt another app's audio). Cvar_Get here adopts whatever
// config.cfg already exec'd, so a saved choice still wins.
static cvar_t *c_audio_mode, *c_volume;
static void EnsureAudioCvars(void)
{
    if (!c_audio_mode) c_audio_mode = Cvar_Get("ios_audio_mode", "2", CVAR_ARCHIVE);  // 2 = Lower Other Audio
    if (!c_volume)     c_volume     = Cvar_Get("ios_volume",     "1", CVAR_ARCHIVE);
}
int   VID_iOS_AudioMode(void) { EnsureAudioCvars(); return c_audio_mode->integer; }
float VID_iOS_Volume(void)    { EnsureAudioCvars(); return c_volume->value; }

// 'game_apply <dir>' — switch game modules safely. Order matters: tearing the
// session down FIRST means the (latched) game cvar applies instantly and its
// filesystem restart happens with nothing playing. Switching a live session's
// module — e.g. the KEX module suddenly pointed at Action's classic data — crashes.
// Also flips com_rerelease: Action (classic API) wants the vanilla protocol/assets.
static void GameApply_f(void)
{
    extern void CL_Disconnect(error_type_t type);
    extern void SV_Shutdown(const char *finalmsg, error_type_t type);
    extern void Cvar_GetLatchedVars(void);
    if (Cmd_Argc() != 2) { Com_Printf("Usage: game_apply <gamedir>\n"); return; }
    char mod[64];
    Q_strlcpy(mod, Cmd_Argv(1), sizeof(mod));   // copy before the buffer is clobbered
    CL_Disconnect(ERR_RECONNECT);
    SV_Shutdown("game changed\n", ERR_RECONNECT);
    Cvar_Set("nextserver", "");   // stop the attract demo loop from hijacking the switch
    Cvar_UserSet("com_rerelease", !Q_stricmp(mod, "action") ? "0" : "1");
    Cvar_UserSet("game", mod);
    Cvar_GetLatchedVars();
    // Re-parse the menu so the mod's shadowing q2repro.menu themes the UI live.
    extern void UI_Reload(void);
    UI_Reload();
}

// True while the classic Action Quake module is the active game (fs_game == "action").
bool VID_iOS_IsAction(void)
{
    extern cvar_t *fs_game;
    return fs_game && !Q_stricmp(fs_game->string, "action");
}

// ---- Touch layout editor console seams (shell implementation in main.m) --------
extern void Q2_iOS_ToggleLayoutEdit(void);
extern void Q2_iOS_ResetLayout(void);
extern void Q2_iOS_LayoutDescription(char *out, int outsz);
extern int  Q2_iOS_FakeTouch(float nx, float ny, int phase);
extern void Q2_iOS_PresentSettings(void);   // native iOS settings panel (ios_settings_ui.m)
extern void Q2_iOS_RemoteConsole(int on);   // dev-only tailnet console (ios_remote_console.m; no-op in public)

// q2_rcon <0|1> — start/stop the remote console (same as the settings toggle). No-op in a public
// build (Q2_DEV_BUILD=0). Handy for enabling it headlessly on the sim.
static void Rcon_f(void)
{
    if (Cmd_Argc() < 2) { Com_Printf("usage: q2_rcon <0|1>\n"); return; }
    Q2_iOS_RemoteConsole(atoi(Cmd_Argv(1)));
}

// Opens the native UIKit iOS settings panel. The engine "iOS settings" menu entry runs this,
// and a gear button in the touch chrome does too — decoupled from the fragile .menu system.
static void IOSSettings_f(void) { Q2_iOS_PresentSettings(); }

// q2_settings_probe <row title substring> [select] — headless scroll-to/tap of a settings
// row, so the panel below the fold can be screenshot on the simulator (see
// ios_settings_ui.m; same rationale as q2_faketouch).
extern void Q2_iOS_SettingsProbe(const char *want, int select);
static void SettingsProbe_f(void)
{
    if (Cmd_Argc() < 2) { Com_Printf("usage: q2_settings_probe <row title substring> [select]\n"); return; }
    Q2_iOS_SettingsProbe(Cmd_Argv(1), Cmd_Argc() > 2 && !Q_stricmp(Cmd_Argv(2), "select"));
}

// touchedit [reset|print] — toggle the on-screen layout editor; `reset` restores shipped
// positions; `print` dumps the live layout in the exact form the defaults table takes, so a
// layout arranged on the device can be promoted to source defaults without transcribing.
static void TouchEdit_f(void)
{
    if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "reset")) { Q2_iOS_ResetLayout(); return; }
    if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "print")) {
        char desc[2048] = {0};
        Q2_iOS_LayoutDescription(desc, sizeof(desc));
        Com_Printf("%s", desc);
        return;
    }
    Q2_iOS_ToggleLayoutEdit();
}

// q2_faketouch <x 0..1> <y 0..1> <down|move|up|zone> — synthetic finger for the editor.
// Injected UIKit touches never reach the touch path on the simulator, so this drives the SAME
// editDrag* methods a real finger does; `zone` queries the move-zone hit test (the only part
// of an invisible zone a screenshot can't prove).
static void FakeTouch_f(void)
{
    if (Cmd_Argc() != 4) { Com_Printf("usage: q2_faketouch <x 0..1> <y 0..1> <down|move|up|zone>\n"); return; }
    const char *ph = Cmd_Argv(3);
    int phase = !Q_stricmp(ph, "down") ? 0 : !Q_stricmp(ph, "move") ? 1 : !Q_stricmp(ph, "zone") ? 3 : 2;
    Q2_iOS_FakeTouch((float)atof(Cmd_Argv(1)), (float)atof(Cmd_Argv(2)), phase);
}

void VID_iOS_RegisterCvars(void)
{
    Cmd_AddCommand("game_apply", GameApply_f);
    Cmd_AddCommand("touchedit", TouchEdit_f);       // customizable touch layout editor
    Cmd_AddCommand("q2_faketouch", FakeTouch_f);     // headless editor test seam
    Cmd_AddCommand("ios_settings", IOSSettings_f);   // native iOS settings panel
    Cmd_AddCommand("q2_settings_probe", SettingsProbe_f);   // headless settings-row test seam
    Cmd_AddCommand("q2_rcon", Rcon_f);               // remote console on/off (dev builds)
    c_sens_x      = Cvar_Get("ios_sens_x",     "3",   CVAR_ARCHIVE);
    c_sens_y      = Cvar_Get("ios_sens_y",     "3",   CVAR_ARCHIVE);
    c_invert_y    = Cvar_Get("ios_invert_y",   "0",   CVAR_ARCHIVE);
    c_touch_scale = Cvar_Get("ios_touch_scale","1.0", CVAR_ARCHIVE);
    c_touch_alpha = Cvar_Get("ios_touch_alpha","1.0", CVAR_ARCHIVE);
    c_touch_lefty = Cvar_Get("ios_touch_lefty","0",   CVAR_ARCHIVE);
    c_haptics     = Cvar_Get("ios_haptics",    "1",   CVAR_ARCHIVE);
    c_display_fps = Cvar_Get("ios_display_fps","0",   CVAR_ARCHIVE);
    c_fps         = Cvar_Get("ios_fps",        "0",   CVAR_ARCHIVE);
    c_gyro        = Cvar_Get("ios_gyro",       "0",   CVAR_ARCHIVE);
    EnsureAudioCvars();   // no-op if S_Init already forced them into existence
}

// Generic cvar read for the native iOS settings panel (it writes via VID_iOS_Command "set ...").
float VID_iOS_CvarValue(const char *name) { return Cvar_VariableValue(name); }

float VID_iOS_SensX(void)     { return c_sens_x     ? c_sens_x->value     : 3; }
float VID_iOS_SensY(void)     { return c_sens_y     ? c_sens_y->value     : 3; }
bool  VID_iOS_InvertY(void)   { return c_invert_y   && c_invert_y->integer; }
float VID_iOS_TouchScale(void){ return c_touch_scale? c_touch_scale->value: 1; }
float VID_iOS_TouchAlpha(void){ return c_touch_alpha? c_touch_alpha->value: 1; }
bool  VID_iOS_TouchLefty(void){ return c_touch_lefty && c_touch_lefty->integer; }
bool  VID_iOS_Haptics(void)   { return c_haptics    ? c_haptics->integer   : 1; }
int   VID_iOS_DisplayFps(void){ return c_display_fps? c_display_fps->integer: 0; }
bool  VID_iOS_ShowFps(void)   { return c_fps        && c_fps->integer; }   // on-screen FPS counter
bool  VID_iOS_Gyro(void)      { return c_gyro       && c_gyro->integer; }

// Opaque menu-action codes used by main.m (avoids exposing K_* to the ObjC side).
enum { IOS_MENU_CLICK = 0, IOS_MENU_UP, IOS_MENU_DOWN, IOS_MENU_LEFT,
       IOS_MENU_RIGHT, IOS_MENU_ENTER, IOS_MENU_BACK };

bool VID_iOS_MenuActive(void)
{
    return (Key_GetDest() & KEY_MENU) != 0;
}

void VID_iOS_MenuMouse(int px, int py)   // device pixels
{
    UI_MouseEvent(px, py);
}

void VID_iOS_MenuKey(int which, bool down)
{
    int k;
    switch (which) {
    case IOS_MENU_CLICK: k = K_MOUSE1;    break;
    case IOS_MENU_UP:    k = K_UPARROW;   break;
    case IOS_MENU_DOWN:  k = K_DOWNARROW; break;
    case IOS_MENU_LEFT:  k = K_LEFTARROW; break;
    case IOS_MENU_RIGHT: k = K_RIGHTARROW;break;
    case IOS_MENU_ENTER: k = K_ENTER;     break;
    case IOS_MENU_BACK:  k = K_ESCAPE;    break;
    default: return;
    }
    Key_Event(k, down, Sys_Milliseconds());
}

// Send a raw engine keynum (e.g. a gamepad K_A_BUTTON) through the bind system, so
// touch buttons and controller buttons resolve to the user's/KEX binds. [gamepad]
void VID_iOS_KeyEvent(int keynum, bool down)
{
    Key_Event(keynum, down, Sys_Milliseconds());
}

// Pad buttons resolve through the bind system, and the binds come from the
// RERELEASE default.cfg's GAMEPAD section — vanilla paks exec a 1997 default.cfg
// with no pad section, so a vanilla install boots with every pad button dead while
// the hardwired analog sticks work (the 2026-07-12 Vision Pro report). Apply the
// rerelease layout to any pad key still unbound: vanilla installs get the standard
// layout, user rebinds (exec'd from config.cfg before this runs) always win.
void VID_iOS_EnsureGamepadBinds(void)
{
    static const struct { const char *key, *act; } defs[] = {
        { "left_trigger",   "+moveup"     },   // the rerelease default.cfg GAMEPAD
        { "right_trigger",  "+attack"     },   // section, verbatim (baseq2/pak0.pak)
        { "x_button",       "cmd help"    },
        { "a_button",       "+moveup"     },
        { "b_button",       "+movedown"   },
        { "left_stick",     "+movedown"   },
        { "right_stick",    "centerview"  },
        { "right_shoulder", "+wheel"      },
        { "left_shoulder",  "+wheel2"     },
        { "DPAD_LEFT",      "cl_weapprev" },
        { "DPAD_RIGHT",     "cl_weapnext" },
        { "DPAD_UP",        "wave 4"      },
    };
    for (size_t i = 0; i < q_countof(defs); i++) {
        int k = Key_StringToKeynum(defs[i].key);
        if (k > 0 && !Key_GetBindingForKey(k)[0])
            Key_SetBinding(k, defs[i].act);
    }
}

// True while the keys menu is capturing a key to bind (send raw pad keys then).
bool VID_iOS_KeyIsWaiting(void)
{
    return Key_IsWaiting();
}

// iOS soft-keyboard → engine text input. Key_Event() itself routes printable key-downs to
// the focused menu field / console (its internal char dispatch), so a down+up of the char
// (or K_ENTER/K_BACKSPACE) code is all that's needed — the same path a USB keyboard takes.
void VID_iOS_KeyChar(int c)
{
    unsigned t = Sys_Milliseconds();
    Key_Event(c, true, t);
    Key_Event(c, false, t);
}
void VID_iOS_KeyPress(int key)   // key = K_ENTER(13) / K_BACKSPACE(8)
{
    unsigned t = Sys_Milliseconds();
    Key_Event(key, true, t);
    Key_Event(key, false, t);
}

// Attract/boot-sequence state: 0 interactive, 1 demo playback, 2 cinematic.
extern int CL_iOS_PassiveState(void);
int VID_iOS_PassiveState(void)
{
    return CL_iOS_PassiveState();
}

extern int CL_iOS_Disconnected(void);
bool VID_iOS_Disconnected(void)   // no server/demo/cinematic → attract can (re)start
{
    return CL_iOS_Disconnected() != 0;
}

extern int CL_iOS_LayoutActive(void);
bool VID_iOS_LayoutActive(void)   // a game-drawn layout/menu is up (Action join/loadout)
{
    return CL_iOS_LayoutActive() != 0;
}

// End the current intro cinematic (→ nextserver fires the demo loop). [attract skip]
extern void SCR_FinishCinematic(void);
void VID_iOS_SkipCinematic(void)
{
    SCR_FinishCinematic();
}

// Look input that bypasses the engine sensitivity path (fixes 3x-fast touch) and
// drives the weapon wheel when open. Degrees for touch/gyro; rate for the stick.
extern void CL_iOS_LookDelta(float yaw, float pitch);
extern void CL_iOS_LookAnalog(float yaw, float pitch);
void VID_iOS_LookDelta(float yaw, float pitch)  { CL_iOS_LookDelta(yaw, pitch); }
void VID_iOS_LookAnalog(float yaw, float pitch) { CL_iOS_LookAnalog(yaw, pitch); }
extern void CL_iOS_WheelCursor(float x, float y);
void VID_iOS_WheelCursor(float x, float y) { CL_iOS_WheelCursor(x, y); }   // touch wheel: cursor follows finger
extern void CL_iOS_SetWheelAnchor(float ux, float uy);
void VID_iOS_SetWheelAnchor(float ux, float uy) { CL_iOS_SetWheelAnchor(ux, uy); }  // render wheel at the button

// Open the GRAPHICAL Quake 2 main menu (logo), not the text in-game menu; ESC backs
// out when a menu is already up. Fixes "tap shows the pure-text menu" over the demo.
extern void VID_iOS_Command(const char *cmd);
void VID_iOS_ToggleMenu(void)
{
    if (Key_GetDest() & KEY_MENU) {
        unsigned t = Sys_Milliseconds();
        Key_Event(K_ESCAPE, true, t);
        Key_Event(K_ESCAPE, false, t);
    } else {
        // NOTE: VID_iOS_Command runs a SINGLE command (Cmd_ExecuteString does not split
        // on ';'), so issue these separately or "pushmenu main" is silently dropped.
        VID_iOS_Command("forcemenuoff");
        VID_iOS_Command("pushmenu main");
    }
}
