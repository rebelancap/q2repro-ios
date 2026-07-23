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
