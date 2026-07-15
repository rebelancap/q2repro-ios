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

// vid_angle.m stereo mode (consumer-side hooks for the SwiftUI compositor loop).
bool VID_iOS_XR3_SetEyeTexture(int eye, void *mtlTexture);  // wrap an app-owned MTLTexture as the eye FBO
void *VID_iOS_XR3_EyeTexture(int eye);                      // the glue-owned eye texture (created on 3D entry)
int  VID_iOS_XR3_FramesRendered(void);                      // stereo frames completed since entering 3D
int  VID_iOS_XR3_EyeGeneration(void);                       // bumps when the eye textures are recreated
void VID_iOS_XR3_ResizeEyes(void);                          // re-sync render size to the panel aspect (main thread)
void VID_iOS_XR3_WaitOn(void *mtlCommandBuffer);            // wait on the engine's stereo-frame fence
int  VID_iOS_XR3_Active(void);

// vid_angle.m: run a console command (FPS toggle etc.)
void VID_iOS_Command(const char *cmd);
