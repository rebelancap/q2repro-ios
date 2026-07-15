#import "SpikeANGLE.h"
#import <Metal/Metal.h>

#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>   // glEGLImageTargetTexture2DOES

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif
#ifndef EGL_METAL_TEXTURE_ANGLE
#define EGL_METAL_TEXTURE_ANGLE 0x34A7
#endif
#ifndef EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE
#define EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE 0x34DD
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_ANGLE 0x34D8
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE 0x34DA
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE 0x34DB
#endif

static EGLDisplay s_dpy = EGL_NO_DISPLAY;
static EGLContext s_ctx = EGL_NO_CONTEXT;
static EGLConfig  s_cfg;
static GLuint     s_glTex, s_fbo;
static int        s_inited;      // 0 untried, 1 ok, <0 failed at that stage
static int        s_lastErr;     // last eglGetError()/GL status at a failure
static int        s_deviceMatch; // 1 if compositor device IS ANGLE's system-default device
static int        s_readBack;    // blue channel *100 read back after clear (~90 if ANGLE wrote)

static id<MTLSharedEvent> s_event;      // signaled by ANGLE when its render commands complete
static uint64_t           s_signalValue;

int SpikeANGLE_LastEGLError(void) { return s_lastErr; }
int SpikeANGLE_DeviceMatch(void)  { return s_deviceMatch; }
int SpikeANGLE_ReadBack(void)     { return s_readBack; }

// After all ANGLE renders this frame, create a fence that signals an MTLSharedEvent when
// ANGLE's queue reaches it, and capture the event + the value it will signal.
void SpikeANGLE_MakeSyncEvent(void) {
    if (s_inited != 1) return;
    EGLSync sync = eglCreateSync(s_dpy, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, NULL);
    if (sync == EGL_NO_SYNC) { s_lastErr = eglGetError(); return; }
    glFlush();   // submit ANGLE's commands (including the event signal)
    void *evt = eglCopyMetalSharedEventANGLE(s_dpy, sync);   // +1 retained id<MTLSharedEvent>
    EGLAttrib lo = 0, hi = 0;
    eglGetSyncAttrib(s_dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, &lo);
    eglGetSyncAttrib(s_dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, &hi);
    s_signalValue = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
    eglDestroySync(s_dpy, sync);
    s_event = (__bridge_transfer id<MTLSharedEvent>)evt;   // take ownership
}

// Make the compositor's present command buffer wait for ANGLE's event → GPU-side cross-queue
// barrier so the present queue sees ANGLE's writes (CPU glFinish alone did not).
void SpikeANGLE_WaitOn(id<MTLCommandBuffer> cmd) {
    if (s_event) [cmd encodeWaitForEvent:s_event value:s_signalValue];
}

// ANGLE-on-Metal, surfaceless — we render into compositor textures via EGLImage+FBO, so we
// never need a window/pbuffer surface. ANGLE's device is the system default (== compositor's
// device on the single-GPU Vision Pro), which the EGLImage path requires.
static int ensureInit(void) {
    if (s_inited) return s_inited;

    const EGLint dattr[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    s_dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
    if (s_dpy == EGL_NO_DISPLAY) { s_lastErr = eglGetError(); return (s_inited = -2); }

    EGLint major, minor;
    if (!eglInitialize(s_dpy, &major, &minor)) { s_lastErr = eglGetError(); return (s_inited = -3); }
    NSLog(@"[spikeangle] ANGLE %s (EGL %d.%d)", eglQueryString(s_dpy, EGL_VENDOR), major, minor);

    const EGLint cfga[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE
    };
    EGLint n = 0;
    if (!eglChooseConfig(s_dpy, cfga, &s_cfg, 1, &n) || n < 1) { s_lastErr = eglGetError(); return (s_inited = -4); }

    const EGLint ctxa[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
    s_ctx = eglCreateContext(s_dpy, s_cfg, EGL_NO_CONTEXT, ctxa);
    if (s_ctx == EGL_NO_CONTEXT) { s_lastErr = eglGetError(); return (s_inited = -5); }

    if (!eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s_ctx)) { s_lastErr = eglGetError(); return (s_inited = -7); }
    glGenTextures(1, &s_glTex);
    glGenFramebuffers(1, &s_fbo);
    return (s_inited = 1);
}

int SpikeANGLE_RenderInto(id<MTLDevice> device, id<MTLTexture> tex, int slice, int eyeIndex) {
    s_deviceMatch = (device == MTLCreateSystemDefaultDevice()) ? 1 : 0;
    int st = ensureInit();
    if (st != 1) return st;

    // Wrap the given slice of the compositor's (layered) Metal texture as an EGLImage, bind it
    // to a GL texture, and hang that off an FBO — the ANGLE path for external Metal textures.
    const EGLint imgAttribs[] = { EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE, slice, EGL_NONE };
    EGLImageKHR img = eglCreateImageKHR(s_dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)(__bridge void *)tex, imgAttribs);
    if (img == EGL_NO_IMAGE_KHR) { s_lastErr = eglGetError(); return -6; }

    glBindTexture(GL_TEXTURE_2D, s_glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s_glTex, 0);

    int rc = 1;
    GLenum fbs = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbs != GL_FRAMEBUFFER_COMPLETE) { s_lastErr = fbs; rc = -8; }
    else {
        glViewport(0, 0, (GLint)tex.width, (GLint)tex.height);
        glClearColor(0.0f, eyeIndex == 0 ? 0.3f : 0.6f, 0.9f, 1.0f);   // vivid blue = ANGLE path
        glClear(GL_COLOR_BUFFER_BIT);
        // Read back what ANGLE actually wrote: rb~90 = ANGLE rendered (so a compositor sync/
        // visibility issue); rb~0 = the clear was a silent no-op (ANGLE render problem).
        GLfloat px[4] = {0, 0, 0, 0};
        glReadPixels(0, 0, 1, 1, GL_RGBA, GL_FLOAT, px);
        s_readBack = (int)(px[2] * 100.0f);
        glFinish();   // ensure ANGLE's Metal work completes before the compositor reads the texture
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    eglDestroyImageKHR(s_dpy, img);
    return rc;
}
