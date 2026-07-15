#pragma once
#import <Metal/Metal.h>

// Spike B: prove ANGLE (GLES-on-Metal) can render directly into a compositor per-eye color
// texture, using the SAME MTLDevice as the compositor (zero-copy). Renders a solid GLES clear
// (blue-ish, distinct from the Metal-path red) into `tex`.
//
// Returns a status so the caller can surface failures without a debugger:
//   1  = ok
//  -1  = eglCreateDeviceANGLE failed   -2 = no display        -3 = eglInitialize failed
//  -4  = eglChooseConfig failed        -5 = eglCreateContext   -6 = pbuffer-from-texture failed
//  -7  = eglMakeCurrent failed
int SpikeANGLE_RenderInto(id<MTLDevice> device, id<MTLTexture> tex, int slice, int eyeIndex);

// Last eglGetError() recorded at a failure (hex), for surfacing without a debugger.
int SpikeANGLE_LastEGLError(void);

// 1 if the compositor's MTLDevice is the same instance as ANGLE's system-default device.
int SpikeANGLE_DeviceMatch(void);

// Blue channel (*100) read back from the texture after ANGLE's clear (~90 = ANGLE wrote it).
int SpikeANGLE_ReadBack(void);

// Cross-queue sync: create a fence after ANGLE's renders, then make the present command buffer
// wait on it so the present queue can see ANGLE's writes.
void SpikeANGLE_MakeSyncEvent(void);
void SpikeANGLE_WaitOn(id<MTLCommandBuffer> cmd);
