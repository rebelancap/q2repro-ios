// ios_bridge.m — small C bridge from the app's touch/controller input to the
// engine's menu (UI) input, so the q2pro menu is navigable on iOS. Pure C (no
// UIKit) so it can include engine headers directly, like the engine .c files.
// Always compiled in the app target; independent of the vid driver.
#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/cmd.h"                     // Cmd_AddCommand, Cmd_Argc/Argv
#include "system/system.h"
#include "client/keys.h"                    // keydest_t, KEY_MENU, Key_GetDest, K_* codes

extern void UI_MouseEvent(int x, int y);    // client/ui/ui.h (internal)
extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a] never notify
extern void Q2_VR_LogNow(const char *msg);
extern void Key_Event(unsigned key, bool down, unsigned time);  // keys.c (private decl)

// =====================================================================================
// PRODUCER FUNNEL — one locked queue, drained at the top of the engine frame
// =====================================================================================
// Until VR, every producer in this file ran on the SAME thread as Qcommon_Frame (the
// main-thread CADisplayLink), so mutating engine state synchronously from a UIKit handler
// was correct by construction and there is no lock, queue or atomic anywhere below. VR
// moves frame ownership to a dedicated engine thread, and on that day every one of these
// entry points becomes a cross-thread write into the client: Key_Event walks the key state
// and the bind table, UI_MouseEvent walks the live menu, Cmd_ExecuteString runs arbitrary
// engine code, and VID_iOS_XR3_ResizeEyes issues GL into a context that is current on
// another thread.
//
// So: while a foreign thread owns the frame, producers ENQUEUE instead of executing, and
// the engine thread drains the queue at the top of its frame. When no foreign thread owns
// the frame (the iOS build, the visionOS 2D window, the 3D panel) the funnel is off and
// every call executes inline exactly as before — this is not a behaviour change for any
// shipping mode, it is a change that only exists while VR is running.
//
// Ordering is preserved (one ring, FIFO), which matters: a `set` followed by the command
// that reads it must not be reordered, and a key down/up pair must not invert.
//
// A producer called FROM the drain (an engine-thread caller) executes inline, so a console
// command that itself calls one of these does not deadlock or defer a frame.

enum {
    Q2P_CMD = 1, Q2P_KEY, Q2P_CHAR, Q2P_KEYPRESS, Q2P_MOUSE, Q2P_LOOKDELTA, Q2P_LOOKANALOG,
    Q2P_ANALOGMOVE, Q2P_WHEELCURSOR, Q2P_WHEELANCHOR, Q2P_RESIZE_EYES, Q2P_AUTOPAUSE,
    Q2P_AUTOPAUSE_RELEASE, Q2P_WRITECONFIG, Q2P_LOG, Q2P_TOGGLEMENU, Q2P_MENUPAUSE
};

#define Q2P_RING 512
#define Q2P_TEXT 256

typedef struct {
    int   kind;
    int   a, b;
    float f0, f1;
    char  text[Q2P_TEXT];
} q2p_item_t;

static q2p_item_t      q2p_ring[Q2P_RING];
static int             q2p_head, q2p_tail;     // head = next write, tail = next read
static unsigned        q2p_dropped;
static pthread_mutex_t q2p_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int      q2p_enabled;            // 1 while a foreign thread owns the frame
static _Atomic(pthread_t) q2p_owner;           // the thread that drains (0 = none)

void Q2_iOS_FunnelEnable(int on, void *ownerThread)
{
    pthread_t t = ownerThread ? *(pthread_t *)ownerThread : (pthread_t)0;
    atomic_store(&q2p_owner, on ? t : (pthread_t)0);
    atomic_store(&q2p_enabled, on ? 1 : 0);
    // [R7b 8a] Shell diagnostics never reach the notify overlay — see Q2_VR_ConPrintf.
    Q2_VR_ConPrintf("q2vr: producer funnel %s\n", on ? "ON (engine thread owns the frame)" : "off");
}

// True when this call must be deferred: the funnel is on AND we are not the drainer.
static bool q2p_defer(void)
{
    if (!atomic_load(&q2p_enabled)) return false;
    pthread_t owner = atomic_load(&q2p_owner);
    return !(owner && pthread_equal(pthread_self(), owner));
}

int Q2_iOS_FunnelActive(void) { return atomic_load(&q2p_enabled); }
int Q2_iOS_OnFrameThread(void)
{
    if (!atomic_load(&q2p_enabled)) return 1;   // main thread IS the frame thread
    pthread_t owner = atomic_load(&q2p_owner);
    return owner && pthread_equal(pthread_self(), owner);
}

static void q2p_push(int kind, int a, int b, float f0, float f1, const char *text)
{
    pthread_mutex_lock(&q2p_lock);
    int next = (q2p_head + 1) % Q2P_RING;
    if (next == q2p_tail) {                    // full: drop the NEWEST, keep history intact
        q2p_dropped++;
        pthread_mutex_unlock(&q2p_lock);
        return;
    }
    q2p_item_t *it = &q2p_ring[q2p_head];
    memset(it, 0, sizeof(*it));
    it->kind = kind; it->a = a; it->b = b; it->f0 = f0; it->f1 = f1;
    if (text) Q_strlcpy(it->text, text, sizeof(it->text));
    q2p_head = next;
    pthread_mutex_unlock(&q2p_lock);
}

// Forward declarations of the inline bodies the drain calls.
static void q2p_exec(const q2p_item_t *it);

// Called at the TOP of the engine frame, on the engine thread. Takes items one at a time
// under the lock rather than draining the whole list at once: an item can enqueue another
// (a console command that runs a bind), and a whole-list drain would either lose those or
// run them against a stale snapshot.
void Q2_iOS_QueueDrain(void)
{
    unsigned dropped;
    for (int guard = 0; guard < Q2P_RING * 2; guard++) {
        q2p_item_t it;
        pthread_mutex_lock(&q2p_lock);
        if (q2p_tail == q2p_head) { pthread_mutex_unlock(&q2p_lock); break; }
        it = q2p_ring[q2p_tail];
        q2p_tail = (q2p_tail + 1) % Q2P_RING;
        pthread_mutex_unlock(&q2p_lock);
        q2p_exec(&it);
    }
    pthread_mutex_lock(&q2p_lock);
    dropped = q2p_dropped; q2p_dropped = 0;
    pthread_mutex_unlock(&q2p_lock);
    if (dropped) Com_EPrintf("q2vr: producer funnel dropped %u item(s)\n", dropped);
}

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

// UIKit-touching console seams. These run inline on whatever thread executes the command,
// which used to be main by construction and, with a VR engine thread, is not. UIKit is
// main-thread-only, so they are BOUNCED to main rather than funnelled: the funnel's job is
// to get engine work onto the engine thread, and this is the opposite journey.
static void q2p_on_main(dispatch_block_t b)
{
    if ([NSThread isMainThread]) b();
    else dispatch_async(dispatch_get_main_queue(), b);
}

// ---- Touch layout editor console seams (shell implementation in main.m) --------
extern void Q2_iOS_ToggleLayoutEdit(void);
extern void Q2_iOS_ResetLayout(void);
extern void Q2_iOS_LayoutDescription(char *out, int outsz);
extern int  Q2_iOS_FakeTouch(float nx, float ny, int phase);
extern void Q2_iOS_PresentSettings(void);   // native iOS settings panel (ios_settings_ui.m)
extern void Q2_iOS_RemoteConsole(int on);   // dev-only tailnet console (ios_remote_console.m; no-op in public)
extern void Q2_iOS_RemoteConsoleAutoStart(void);   // [R10] remembered switch, default ON in dev builds
extern void Q2_VR_RegisterCommands(void);   // q2_vr_dumps.m — harness console seams

// q2_rcon <0|1> — start/stop the remote console (same as the settings toggle). No-op in a public
// build (Q2_DEV_BUILD=0). Handy for enabling it headlessly on the sim.
static void Rcon_f(void)
{
    if (Cmd_Argc() < 2) { Com_Printf("usage: q2_rcon <0|1>\n"); return; }
    Q2_iOS_RemoteConsole(atoi(Cmd_Argv(1)));
}

// Opens the native UIKit iOS settings panel. The engine "iOS settings" menu entry runs this,
// and a gear button in the touch chrome does too — decoupled from the fragile .menu system.
static void IOSSettings_f(void) { q2p_on_main(^{ Q2_iOS_PresentSettings(); }); }

// q2_settings_probe <row title substring> [select] — headless scroll-to/tap of a settings
// row, so the panel below the fold can be screenshot on the simulator (see
// ios_settings_ui.m; same rationale as q2_faketouch).
extern void Q2_iOS_SettingsProbe(const char *want, int select);
static void SettingsProbe_f(void)
{
    if (Cmd_Argc() < 2) { Com_Printf("usage: q2_settings_probe <row title substring> [select]\n"); return; }
    NSString *want = @(Cmd_Argv(1));
    int sel = Cmd_Argc() > 2 && !Q_stricmp(Cmd_Argv(2), "select");
    q2p_on_main(^{ Q2_iOS_SettingsProbe(want.UTF8String, sel); });
}

// touchedit [reset|print] — toggle the on-screen layout editor; `reset` restores shipped
// positions; `print` dumps the live layout in the exact form the defaults table takes, so a
// layout arranged on the device can be promoted to source defaults without transcribing.
static void TouchEdit_f(void)
{
    if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "reset")) { q2p_on_main(^{ Q2_iOS_ResetLayout(); }); return; }
    if (Cmd_Argc() == 2 && !Q_stricmp(Cmd_Argv(1), "print")) {
        char desc[2048] = {0};
        Q2_iOS_LayoutDescription(desc, sizeof(desc));
        Com_Printf("%s", desc);
        return;
    }
    q2p_on_main(^{ Q2_iOS_ToggleLayoutEdit(); });
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
    float fx = (float)atof(Cmd_Argv(1)), fy = (float)atof(Cmd_Argv(2));
    q2p_on_main(^{ Q2_iOS_FakeTouch(fx, fy, phase); });
}

// ---- Auto-pause on immersive exit (guide §5; §10 #11 is the toggle trap) --------
// A player yanked out of an immersive space by the Digital Crown is being shot at by a
// world they can no longer see. `pause` is a TOGGLE, so a blind second toggle on the way
// back in would UN-pause a player who had paused themselves: track whether WE paused, and
// release exactly once on the first sign the player is back at the controls.
extern void VID_iOS_Command(const char *cmd);
int  VID_iOS_PassiveState(void);   // defined below
bool VID_iOS_Disconnected(void);   // defined below
bool VID_iOS_MenuActive(void);     // defined below
void VID_iOS_SkipCinematic(void);  // defined below
void VID_iOS_ToggleMenu(void);     // defined below
extern void Q2_VR_LogNow(const char *msg);
static void Q2_iOS_MenuPauseSet(bool want);
static bool s_autopaused;
static void Q2_iOS_AutoPauseNow(void);
static void Q2_iOS_AutoPauseReleaseNow(void);

void Q2_iOS_AutoPause(void)
{
    if (q2p_defer()) { q2p_push(Q2P_AUTOPAUSE, 0, 0, 0, 0, NULL); return; }
    Q2_iOS_AutoPauseNow();
}
static void Q2_iOS_AutoPauseNow(void)
{
    if (s_autopaused) return;
    if (VID_iOS_PassiveState() != 0) return;              // demo/cinematic — nothing to pause
    if (VID_iOS_Disconnected()) return;                   // no live game
    if (Cvar_VariableValue("cl_paused") != 0) return;     // the player already paused
    VID_iOS_Command("pause");
    s_autopaused = Cvar_VariableValue("cl_paused") != 0;
    if (s_autopaused) Q2_VR_LogNow("q2vr: auto-paused on immersive exit");
}

void Q2_iOS_AutoPauseRelease(void)
{
    if (q2p_defer()) { q2p_push(Q2P_AUTOPAUSE_RELEASE, 0, 0, 0, 0, NULL); return; }
    Q2_iOS_AutoPauseReleaseNow();
}
static void Q2_iOS_AutoPauseReleaseNow(void)
{
    if (!s_autopaused) return;
    s_autopaused = false;
    if (Cvar_VariableValue("cl_paused") != 0) {
        VID_iOS_Command("pause");
        Q2_VR_LogNow("q2vr: auto-pause released");
    }
}

bool Q2_iOS_AutoPauseHeld(void) { return s_autopaused; }

// ---- The menu pause, and the ONE Start button (R7b items 6 and 7) ---------------------
// Second headset verdict: "the OPTIONS/start button should be pause menu". It opened
// the menu and left the world running behind it, which in VR means being shot while reading a
// settings list you cannot leave fast enough.
//
// A SEPARATE TRACKED FLAG FROM THE AUTO-PAUSE, deliberately. They look like the same
// mechanism and are not: the auto-pause is released by the first sign of input (that is the
// whole point of it — the player is back at the controls), and VID_iOS_KeyEvent calls the
// release on every key DOWN. Menu navigation is key-downs. Sharing the flag would therefore
// un-pause the game on the first press inside the menu, which is the state this exists to
// prevent. This one is released by the menu CLOSING and by nothing else.
//
// `pause` is a TOGGLE, so — exactly as the auto-pause does — only what WE paused may be
// released, and the flag is set from the cvar's answer rather than from the intent.
static bool s_menupaused;

static void Q2_iOS_MenuPauseSet(bool want)
{
    if (want == s_menupaused) return;
    if (want) {
        if (VID_iOS_PassiveState() != 0) return;            // a demo/cinematic has nothing to pause
        if (VID_iOS_Disconnected()) return;                 // no live game
        if (Cvar_VariableValue("cl_paused") != 0) return;   // the player already paused
        VID_iOS_Command("pause");
        s_menupaused = Cvar_VariableValue("cl_paused") != 0;
        if (s_menupaused) Q2_VR_LogNow("q2vr: menu paused the game");
    } else {
        s_menupaused = false;
        if (Cvar_VariableValue("cl_paused") != 0) {
            VID_iOS_Command("pause");
            Q2_VR_LogNow("q2vr: menu pause released");
        }
    }
}

// Reconciliation, called once per input poll from the pad driver. The menu can be closed by
// routes this file never sees — a bound key, the engine's own `forcemenuoff`, a level change —
// so a release that lived only in the toggle path would strand a paused game behind a menu
// that is no longer there. One predicate, checked from the place input already runs.
//
// EDGE-TRIGGERED, and that is not an optimisation. The poll runs at 90 Hz; a level-triggered
// version whose `pause` was refused (a demo is playing, the game is disconnected) would push
// a producer item every 11 ms for as long as the menu stayed up, and the ring is 512 deep.
// One transition, one attempt.
static bool s_menupause_want;

void Q2_iOS_MenuPauseTick(void)
{
    bool want = VID_iOS_MenuActive();
    if (want == s_menupause_want) return;
    s_menupause_want = want;
    if (q2p_defer()) { q2p_push(Q2P_MENUPAUSE, want ? 1 : 0, 0, 0, 0, NULL); return; }
    Q2_iOS_MenuPauseSet(want);
}

bool Q2_iOS_MenuPauseHeld(void) { return s_menupaused; }

// ONE physical Start press (☰ on a gamepad, the ☰ or the off hand's top face button on a Sense
// pair). Everything that is "the gamepad's menu button" routes through here so the two input
// stacks cannot drift — which is the whole of R7b item 7's claim that the pair IS a gamepad.
//
// Skipping a cinematic comes FIRST (item 6): "i had to sit there the whole time. stupid." A tap
// on the iPhone's glass has always skipped it; no controller ever could, on either stack.
void VID_iOS_PadStartButton(void)
{
    // Only while no real menu is up — a player who opened the menu DURING the intro is
    // pressing Start to CLOSE the menu, not to skip the movie (same guard as every other
    // skip path: q2_vr_hands.m UIFrame, main.m face-button skip).
    if (VID_iOS_PassiveState() == 2 && !VID_iOS_MenuActive()) { VID_iOS_SkipCinematic(); return; }
    VID_iOS_ToggleMenu();
    // Applied immediately rather than waiting for the next tick: opening the menu and taking a
    // rocket in the frame between is exactly the complaint.
    Q2_iOS_MenuPauseTick();
}

// Write the archived cvars + bindings out NOW. Cmd_ExecuteString runs inline, so on the
// engine thread this returns only once the file is on disk — which is the point: a system
// dismissal is frequently the first half of a swipe-kill, and nothing else writes then.
void Q2_iOS_WriteConfigSync(void)
{
    // On the engine thread this is genuinely synchronous (Cmd_ExecuteString runs inline and
    // returns with the file on disk), which is the point — a system dismissal is frequently
    // the first half of a swipe-kill and nothing else writes then. Off the engine thread it
    // must go through the funnel and is therefore only synchronous-ish; the VR exit path
    // orders it BEFORE the engine thread stops so it still lands before the space goes away.
    if (q2p_defer()) { q2p_push(Q2P_WRITECONFIG, 0, 0, 0, 0, NULL); return; }
    Cmd_ExecuteString(&cmd_buffer, "writeconfig_boot");
}

void VID_iOS_RegisterCvars(void)
{
    Cmd_AddCommand("game_apply", GameApply_f);
    Cmd_AddCommand("touchedit", TouchEdit_f);       // customizable touch layout editor
    Cmd_AddCommand("q2_faketouch", FakeTouch_f);     // headless editor test seam
    Cmd_AddCommand("ios_settings", IOSSettings_f);   // native iOS settings panel
    Cmd_AddCommand("q2_settings_probe", SettingsProbe_f);   // headless settings-row test seam
    Cmd_AddCommand("q2_rcon", Rcon_f);               // remote console on/off (dev builds)
    Q2_iOS_RemoteConsoleAutoStart();                 // [R10] bring it up if remembered (default ON in dev)
    Q2_VR_RegisterCommands();                        // *NOW dumps, injection stubs, black box
#if defined(Q2_XR_UI) && Q2_XR_UI
    extern void Q2_VR_RegisterInputCommands(void);   // q2_vr_input.m
    extern void Q2_VR_RepairLeftoverStash(void);
    Q2_VR_RegisterInputCommands();
    // A cvar stash still present at LAUNCH means the app never got to run its VR exit — a
    // crash, or a swipe-kill out of the space. That is precisely the case the stash exists
    // for, so the repair is unconditional and writes the config immediately: if the next
    // thing that happens is another crash, the repair has already stuck.
    Q2_VR_RepairLeftoverStash();
#endif
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

void VID_iOS_KeyEvent(int keynum, bool down);

// Opaque menu-action codes used by main.m (avoids exposing K_* to the ObjC side).
enum { IOS_MENU_CLICK = 0, IOS_MENU_UP, IOS_MENU_DOWN, IOS_MENU_LEFT,
       IOS_MENU_RIGHT, IOS_MENU_ENTER, IOS_MENU_BACK };

bool VID_iOS_MenuActive(void)
{
    return (Key_GetDest() & KEY_MENU) != 0;
}

void VID_iOS_MenuMouse(int px, int py)   // device pixels
{
    if (q2p_defer()) { q2p_push(Q2P_MOUSE, px, py, 0, 0, NULL); return; }
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
    VID_iOS_KeyEvent(k, down);
}

// Send a raw engine keynum (e.g. a gamepad K_A_BUTTON) through the bind system, so
// touch buttons and controller buttons resolve to the user's/KEX binds. [gamepad]
void VID_iOS_KeyEvent(int keynum, bool down)
{
    if (down) Q2_iOS_AutoPauseRelease();   // first play attempt after an immersive exit
    if (q2p_defer()) { q2p_push(Q2P_KEY, keynum, down ? 1 : 0, 0, 0, NULL); return; }
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
    if (q2p_defer()) { q2p_push(Q2P_CHAR, c, 0, 0, 0, NULL); return; }
    unsigned t = Sys_Milliseconds();
    Key_Event(c, true, t);
    Key_Event(c, false, t);
}
void VID_iOS_KeyPress(int key)   // key = K_ENTER(13) / K_BACKSPACE(8)
{
    if (q2p_defer()) { q2p_push(Q2P_KEYPRESS, key, 0, 0, 0, NULL); return; }
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
extern void CL_SetAnalogMove(float forward, float side);
extern void CL_iOS_WheelCursor(float x, float y);
extern void CL_iOS_SetWheelAnchor(float ux, float uy);
void VID_iOS_LookDelta(float yaw, float pitch)  {
    Q2_iOS_AutoPauseRelease();
    if (q2p_defer()) { q2p_push(Q2P_LOOKDELTA, 0, 0, yaw, pitch, NULL); return; }
    CL_iOS_LookDelta(yaw, pitch);
}
void VID_iOS_LookAnalog(float yaw, float pitch) {
    Q2_iOS_AutoPauseRelease();
    if (q2p_defer()) { q2p_push(Q2P_LOOKANALOG, 0, 0, yaw, pitch, NULL); return; }
    CL_iOS_LookAnalog(yaw, pitch);
}
// Touch/gamepad analog move. main.m used to call CL_SetAnalogMove directly from UIKit touch
// handlers; that is a cross-thread write into the client the moment the engine leaves main,
// so every call site goes through here instead.
void VID_iOS_AnalogMove(float forward, float side) {
    if (q2p_defer()) { q2p_push(Q2P_ANALOGMOVE, 0, 0, forward, side, NULL); return; }
    CL_SetAnalogMove(forward, side);
}
void VID_iOS_WheelCursor(float x, float y) {
    if (q2p_defer()) { q2p_push(Q2P_WHEELCURSOR, 0, 0, x, y, NULL); return; }
    CL_iOS_WheelCursor(x, y);   // touch wheel: cursor follows finger
}
void VID_iOS_SetWheelAnchor(float ux, float uy) {
    if (q2p_defer()) { q2p_push(Q2P_WHEELANCHOR, 0, 0, ux, uy, NULL); return; }
    CL_iOS_SetWheelAnchor(ux, uy);  // render wheel at the button
}

// Open the GRAPHICAL Quake 2 main menu (logo), not the text in-game menu; ESC backs
// out when a menu is already up. Fixes "tap shows the pure-text menu" over the demo.
extern void VID_iOS_Command(const char *cmd);
void VID_iOS_ToggleMenu(void)
{
    if (q2p_defer()) { q2p_push(Q2P_TOGGLEMENU, 0, 0, 0, 0, NULL); return; }
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

// =====================================================================================
// Funnel execution — the engine-thread side of every deferred producer
// =====================================================================================
// One switch, so the set of things that can cross the thread boundary is enumerable in one
// place. Anything not listed here is either engine-thread-only already or is UIKit work
// that must stay on main (the touch overlay, the FPS label, the settings sheet) and is
// bounced back to main rather than queued.
extern void VID_iOS_XR3_ResizeEyes_Now(void);
extern void Q2_VR_LogNow(const char *msg);

static void q2p_exec(const q2p_item_t *it)
{
    unsigned t = Sys_Milliseconds();
    switch (it->kind) {
    case Q2P_CMD:            Cmd_ExecuteString(&cmd_buffer, it->text); break;
    case Q2P_KEY:            Key_Event(it->a, it->b != 0, t); break;
    case Q2P_CHAR:           Key_Event(it->a, true, t); Key_Event(it->a, false, t); break;
    case Q2P_KEYPRESS:       Key_Event(it->a, true, t); Key_Event(it->a, false, t); break;
    case Q2P_MOUSE:          UI_MouseEvent(it->a, it->b); break;
    case Q2P_LOOKDELTA:      CL_iOS_LookDelta(it->f0, it->f1); break;
    case Q2P_LOOKANALOG:     CL_iOS_LookAnalog(it->f0, it->f1); break;
    case Q2P_ANALOGMOVE:     CL_SetAnalogMove(it->f0, it->f1); break;
    case Q2P_WHEELCURSOR:    CL_iOS_WheelCursor(it->f0, it->f1); break;
    case Q2P_WHEELANCHOR:    CL_iOS_SetWheelAnchor(it->f0, it->f1); break;
#if defined(Q2_XR_UI) && Q2_XR_UI
    case Q2P_RESIZE_EYES:    VID_iOS_XR3_ResizeEyes_Now(); break;
#endif
    case Q2P_AUTOPAUSE:      Q2_iOS_AutoPauseNow(); break;
    case Q2P_AUTOPAUSE_RELEASE: Q2_iOS_AutoPauseReleaseNow(); break;
    case Q2P_WRITECONFIG:    Cmd_ExecuteString(&cmd_buffer, "writeconfig_boot"); break;
    case Q2P_LOG:            Q2_VR_LogNow(it->text); break;
    case Q2P_TOGGLEMENU:     VID_iOS_ToggleMenu(); break;
    case Q2P_MENUPAUSE:      Q2_iOS_MenuPauseSet(it->a != 0); break;   // [R7b item 7]
    default: break;
    }
}

// The two entry points other translation units use to defer their own work.
void Q2_iOS_QueueCommand(const char *cmd) { q2p_push(Q2P_CMD, 0, 0, 0, 0, cmd); }
void Q2_iOS_QueueSimple(int kind)         { q2p_push(kind, 0, 0, 0, 0, NULL); }
int  Q2_iOS_QueueKind_ResizeEyes(void)    { return Q2P_RESIZE_EYES; }
int  Q2_iOS_QueueKind_Log(void)           { return Q2P_LOG; }
void Q2_iOS_QueueLog(const char *msg)     { q2p_push(Q2P_LOG, 0, 0, 0, 0, msg); }
int  Q2_iOS_ShouldDefer(void)             { return q2p_defer() ? 1 : 0; }
// How many producer items are still waiting. The VR exit path polls this so the
// synchronous config write has actually HAPPENED before the engine thread is asked to
// stop — a write that dies with the thread is exactly the failure the sync write exists
// to prevent.
int  Q2_iOS_QueuePending(void)
{
    pthread_mutex_lock(&q2p_lock);
    int n = (q2p_head - q2p_tail + Q2P_RING) % Q2P_RING;
    pthread_mutex_unlock(&q2p_lock);
    return n;
}
