// Swift bridging header for the visionOS 3D (immersive) variant.
#pragma once
#import <Metal/Metal.h>

// Engine boot + per-frame drive (xr_boot.m).
void Q2_XR_Boot(void);
void Q2_XR_Frame(void);            // step sim + render current (left) eye into the bound FBO
void Q2_XR_PollInput(void);        // poll the game controller → engine (called inside Q2_XR_Frame)
void Q2_XR_SetStereo(float offset); // per-eye view shift (world units along view-right); 0 = mono
int  Q2_XR_RenderView(void);       // re-render current state (no sim step) into the bound FBO;
                                   // 0 = skipped (no world rendered this frame — show left eye in both)
bool Q2_XR_HasData(void);          // true iff game data present; else writes a Files-visible readme
int  Q2_XR_ConsoleOpen(void);      // 1 while the pull-down console is up (diagnostic)
const char *Q2_XR_DataMode(void);  // "rerelease" / "vanilla" / "?" — which data actually loaded
void Q2_XR_SetHideGun(int hide);   // hide (1) / show (0) the weapon viewmodel (cl_gun)
void Q2_XR_SetConvergence(float c); // stereo convergence / "crosshair distance" (world units)

// Immersive render bridge (xr_render.m).
void VID_iOS_XR_SetEye(id<MTLTexture> tex, int slice, int w, int h);   // point engine FBO at eye slice
void VID_iOS_XR_BlitEyes(id<MTLTexture> tex, int fromSlice, int toSlice, int w, int h); // mono → both eyes
void VID_iOS_XR_MakeSync(void);                                        // fence ANGLE's work
void VID_iOS_XR_WaitOn(id<MTLCommandBuffer> cmd);                      // present queue waits on it
void VID_iOS_XR_Finish(void);                                         // hard glFinish (proven path)
int  VID_iOS_XR_ProbeLuma(id<MTLTexture> tex, int slice);            // grid-max brightness*1000
int  VID_iOS_XR_LastFBO(void);                                       // FBO handed to engine (0 = wrap failed)
const char *VID_iOS_XR_ConsoleTail(void);                            // engine console tail (diagnostic)
