// Swift bridging header for the MERGED visionOS 2D+3D app (Q2_XR_UI variant).
// (XRBridging.h is the standalone 3D app's header; this one only declares the
// merged-app surface: the hosted game VC + the stereo mode + consumer hooks.)
#pragma once
#import <UIKit/UIKit.h>

// main.m (Q2_XR_UI): SwiftUI-hosted game view controller (builds GameVC+GLView, boots engine).
UIViewController *Q2_MakeGameViewController(void);
void Q2_XR3_EngineEnter3D(void);   // engine → offscreen stereo (call BEFORE openImmersiveSpace)
void Q2_XR3_EngineExit3D(void);    // engine → window surface   (call AFTER dismissImmersiveSpace)
void Q2_XR3_ScenePhase(int active); // scene became active (1) / backgrounded (0) — audio + link

// xr3_glue.m stereo mode (consumer-side hooks for the SwiftUI compositor loop).
void *VID_iOS_XR3_EyeTexture(int eye);                      // last PUBLISHED (GPU-complete) eye texture, or NULL
int  VID_iOS_XR3_FramesRendered(void);                      // published stereo frames since entering 3D
int  VID_iOS_XR3_InFlight(void);                            // engine frames submitted but not GPU-complete (0–2)
int  VID_iOS_XR3_EyeGeneration(void);                       // bumps when the eye textures are recreated
void VID_iOS_XR3_ResizeEyes(void);                          // re-sync render size to the panel aspect (main thread)
int  VID_iOS_XR3_Active(void);

// vid_angle.m: run a console command (FPS toggle etc.)
void VID_iOS_Command(const char *cmd);
// main.m: diagnostics routed into the engine console log (console-safe text only)
void Q2_XR3_Log(const char *msg);
// main.m: the GAME window's size (CGSizeZero when not attached) — never keyWindow
CGSize Q2_XR3_GameWindowSize(void);

// ios_audio.m: sound-stage anchoring. The DESIRED mode is stored engine-side and
// re-asserted after every Q2_iOS_AudioApply — a route change or an interruption would
// otherwise silently drop it (SHELL-GAPS item 11). 0 automatic / 1 front / 2 bypassed.
void Q2_iOS_SetSpatialMode(int mode);
int  Q2_iOS_SpatialMode(void);

// ios_bridge.m: immersive-exit product gaps (SHELL-GAPS items 4 and 5).
void Q2_iOS_WriteConfigSync(void);     // writeconfig NOW — a crown exit never backgrounds
void Q2_iOS_AutoPause(void);           // pause a live game the player can no longer see
void Q2_iOS_AutoPauseRelease(void);    // tracked release; `pause` is a toggle
bool Q2_iOS_AutoPauseHeld(void);

// ios_remote_console.m: the dev-only tailnet console (tcp/8770). Available() is 0 in a
// public build, and the settings sheet hides the row when it is.
void Q2_iOS_RemoteConsole(int on);
int  Q2_iOS_RemoteConsoleRunning(void);
int  Q2_iOS_RemoteConsoleAvailable(void);

// q2_vr_dumps.c: the shell-side diagnostics the VR campaign asserts against.
void Q2_VR_BlackBoxPin(const char *key, const char *line);   // PINNED region (replaces by key)
void Q2_VR_BlackBoxLog(const char *line);                    // ROLLING tail
void Q2_VR_BlackBoxFlush(int force);                         // force=1 bypasses the ~1 Hz coalesce
void Q2_VR_SetMode(int mode);                                // 0 = 2D, 1 = 3D panel, 2 = VR
int  Q2_VR_Mode(void);
float Q2_VR_SimIPD(void);              // synthesised IPD (the sim reports views = 1)
// [R14b] MEMORY BREADCRUMBS. phys_footprint is what the OS kills a process over and
// os_proc_available_memory is the headroom left before it does; the peak is the high-water
// mark since launch. Read once a second by the compositor for the VRCLOCK tail.
void Q2_VR_MemStats(float *cur_mb, float *peak_mb, float *avail_mb);
int  Q2_VR_MemLine(char *out, int size);       // "mem=<cur>MB/<avail>MB peak=<peak>MB"
void Q2_VR_MarkRunning(int running);           // arm (1) / clear (0) the unclean-exit marker
// [R16] MAIN TICKS THAT FIRED WHILE VR OWNED THE FRAME. Zero is the healthy value: the
// display link is paused for the whole immersive session, so anything above zero means
// something unpaused it behind VR's back and the main thread was about to drive the engine
// concurrently with the VR thread. Reported in the once-a-second VRCLOCK line as
// `mainticks=`; the accompanying MAINTICK line names who did it.
unsigned Q2_VR_MainTicksInVR(void);

// ---- VR (R1) --------------------------------------------------------------------------
// The rendezvous, frame ownership, two-phase sizing and depth handoff all live behind
// q2_vr_glue.h so the Swift compositor and the engine-side glue share one ABI.
#import "q2_vr_glue.h"

void Q2_XR3_EngineEnterVR(void);       // engine thread takes the frame, BEFORE the space opens
int  Q2_XR3_EngineVRStopRequest(void); // request, never a join
int  Q2_XR3_EngineVRStopped(void);     // poll
void Q2_XR3_EngineExitVR(void);        // idempotent, unconditional finalize
int  Q2_iOS_QueuePending(void);        // producer-funnel depth (the exit path waits on it)
void VID_iOS_XR3_EyeSize(int *w, int *h);
void VID_iOS_XR3_UIRect(int *w, int *h);   // R5: the HUD's widescreen sub-rect (0x0 = whole)
