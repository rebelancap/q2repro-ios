// xr3_glue.m — stereo machinery for the MERGED visionOS 2D+3D app (Q2_XR_UI).
// UIKit-free on purpose: UIKit transitively imports the system OpenGLES module, whose GL
// prototypes are marked unavailable on visionOS and shadow ANGLE's (the xr_render.m trap).
// Foundation + Metal + ANGLE's GLES headers own the GL symbols here.
//
// Shape (vkQuake blueprint): the engine renders both eyes per tick (main thread, ANGLE)
// into two app-owned Metal textures wrapped ONCE as GL FBOs; the SwiftUI compositor loop
// is a pure consumer that waits on a shared-event fence and samples the textures.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include "shared/shared.h"
#include "common/common.h"
#include "client/video.h"
#include "refresh/refresh.h"

#ifndef EGL_METAL_TEXTURE_ANGLE
#define EGL_METAL_TEXTURE_ANGLE 0x34A7
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_ANGLE 0x34D8
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE 0x34DA
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE 0x34DB
#endif

extern void V_SetStereoOffset(float offset);           // overlay 0016
extern void V_SetStereoConvergence(float c);           // overlay 0020
extern void VID_iOS_XR3_GetWindowSize(int *w, int *h); // vid_angle.m

int q2_xr3_mode;   // read by vid_angle.m's swap gate

// Eye slots: the Swift consumer hands in the MTLTextures (any thread — stored only);
// the GL wrap happens LAZILY on the engine thread, where the ANGLE context is current.
static struct {
    void *mtl;               // retained MTLTexture (via CFBridgingRetain)
    EGLImageKHR img;
    GLuint glTex, fbo, depthRb;
    int w, h;
    bool wrapped;
} s_eye[2];

static id<MTLSharedEvent> s_event;
static uint64_t s_signal;

bool VID_iOS_XR3_SetEyeTexture(int eye, void *mtlTexture) {
    if (eye < 0 || eye > 1 || !mtlTexture) return false;
    if (s_eye[eye].mtl == mtlTexture) return true;
    if (s_eye[eye].mtl) CFRelease(s_eye[eye].mtl);
    s_eye[eye].mtl = (void *)CFRetain(mtlTexture);
    s_eye[eye].wrapped = false;    // (re)wrap lazily on the engine thread
    id<MTLTexture> t = (__bridge id<MTLTexture>)mtlTexture;
    s_eye[eye].w = (int)t.width; s_eye[eye].h = (int)t.height;
    return true;
}

// Engine thread only (ANGLE context current). Returns the FBO id or 0.
static GLuint xr3_wrap(int eye) {
    if (s_eye[eye].wrapped) return s_eye[eye].fbo;
    if (!s_eye[eye].mtl) return 0;
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return 0;
    if (s_eye[eye].img) {          // free a previous wrap (texture was replaced)
        eglDestroyImageKHR(dpy, s_eye[eye].img);
        glDeleteTextures(1, &s_eye[eye].glTex);
        glDeleteRenderbuffers(1, &s_eye[eye].depthRb);
        glDeleteFramebuffers(1, &s_eye[eye].fbo);
        s_eye[eye].img = NULL;
    }
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)s_eye[eye].mtl, NULL);
    if (img == EGL_NO_IMAGE_KHR) { Com_EPrintf("xr3: no EGLImage 0x%x\n", eglGetError()); return 0; }
    GLuint glTex = 0, fbo = 0, rb = 0;
    glGenTextures(1, &glTex); glBindTexture(GL_TEXTURE_2D, glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTex, 0);
    // Real z-buffer for the engine's 3D pass — without it the scene z-fights (holes,
    // the viewmodel drawing through itself).
    glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, s_eye[eye].w, s_eye[eye].h);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, rb);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE) { Com_EPrintf("xr3: eye FBO incomplete 0x%x\n", st); return 0; }
    s_eye[eye].img = img; s_eye[eye].glTex = glTex; s_eye[eye].fbo = fbo; s_eye[eye].depthRb = rb;
    s_eye[eye].wrapped = true;
    return fbo;
}

int VID_iOS_XR3_Active(void) { return q2_xr3_mode; }

// The glue OWNS the eye textures and creates them on demand — BEFORE the immersive space
// opens (Q2_XR3_EngineEnter3D → SetMode runs first). Creating them in the panel renderer
// was the black-first-entry bug: on the first entry SetMode found no textures and failed,
// the engine kept rendering to the window, and the panel sampled never-written memory.
static int s_framesRendered;   // stereo frames completed since entering 3D
static void xr3_target_size(int *w, int *h);
static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace);
static void xr3_ensure_textures(void) {
    if (s_eye[0].mtl && s_eye[1].mtl) return;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    // 2880x2160 (6.2 MP, 4:3) supersamples the panel (was 2048x1536 — read as soft), and
    // MIPMAPPED: a 3D scene on a flat panel is heavily minified (far walls/floors); linear
    // minification without mips shimmers = "noisy/not crisp". The consumer regenerates the
    // mip chain each frame and samples with a mip filter. (Crispness spec, levers #1+#2.)
    int w = 0, h = 0; xr3_target_size(&w, &h);
    xr3_make_textures(dev, w, h, false);
}

// Render size = the panel's ASPECT at a fixed ~8.3 MP budget (vkQuake's formula:
// w = sqrt(budget * aspect)). The render always matches the panel shape 1:1 — a
// mismatched aspect stretches the image (the 4:3-onto-16:9 "fat geometry" bug),
// and this is what makes ultra-widescreen panels render true Hor+ widescreen.
static void xr3_target_size(int *w, int *h) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    float halfW = [d objectForKey:@"xr_halfW"] ? (float)[d floatForKey:@"xr_halfW"] : 2.75f;
    float halfH = [d objectForKey:@"xr_halfH"] ? (float)[d floatForKey:@"xr_halfH"] : 1.55f;
    float aspect = (halfH > 0.01f) ? (halfW / halfH) : (16.0f / 9.0f);
    if (aspect < 0.5f) aspect = 0.5f;
    if (aspect > 4.0f) aspect = 4.0f;   // sane clamp (extreme shapes explode one dimension)
    const float budget = 3840.0f * 2160.0f;
    float fw = sqrtf(budget * aspect);
    *w = ((int)lroundf(fw) + 7) & ~7;           // multiple of 8
    *h = ((int)lroundf(fw / aspect) + 7) & ~7;
}

static int s_eyeGeneration;
static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:w height:h mipmapped:YES];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    for (int e = 0; e < 2; e++) if (replace || !s_eye[e].mtl) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (t) VID_iOS_XR3_SetEyeTexture(e, (__bridge void *)t);   // old texture released; GPU keeps in-flight refs alive
    }
    s_eyeGeneration++;
}

int VID_iOS_XR3_EyeGeneration(void) { return s_eyeGeneration; }

// Re-sync the render size to the panel's current aspect (slider release / entry). Engine
// thread only. No-op within 16 px (vkQuake's threshold) or when textures don't exist yet.
void VID_iOS_XR3_ResizeEyes(void) {
    if (!s_eye[0].mtl) return;
    int w = 0, h = 0; xr3_target_size(&w, &h);
    if (abs(w - s_eye[0].w) <= 16 && abs(h - s_eye[0].h) <= 16) return;
    s_framesRendered = 0;   // consumer draws dim-only until a frame lands at the new size
    xr3_make_textures(MTLCreateSystemDefaultDevice(), w, h, true);
    if (q2_xr3_mode) {      // engine renders the new aspect immediately (Hor+ FOV)
        R_ModeChanged(w, h, 0);
        SCR_ModeChanged();
        Com_Printf("xr3: render re-synced to %dx%d\n", w, h);
    }
}
void *VID_iOS_XR3_EyeTexture(int eye) { return s_eye[eye & 1].mtl; }
int VID_iOS_XR3_FramesRendered(void) { return s_framesRendered; }

// Enter/leave stereo (engine thread). On enter the engine's render size becomes the eye
// texture size; on exit it returns to the window surface size. Window never touched in 3D.
void VID_iOS_XR3_SetMode(int on) {
    if (q2_xr3_mode == !!on) return;
    if (on) xr3_ensure_textures();
    if (on && (!s_eye[0].mtl || !s_eye[1].mtl)) { Com_EPrintf("xr3: no eye textures\n"); return; }
    q2_xr3_mode = !!on;
    if (on) {
        s_framesRendered = 0;   // the panel draws passthrough-only until a real frame lands
        R_ModeChanged(s_eye[0].w, s_eye[0].h, 0);
        SCR_ModeChanged();
        Com_Printf("xr3: stereo ON (%dx%d per eye)\n", s_eye[0].w, s_eye[0].h);
    } else {
        V_SetStereoOffset(0);
        R_SetDefaultFramebuffer(0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        int w = 0, h = 0; VID_iOS_XR3_GetWindowSize(&w, &h);
        if (w && h) { R_ModeChanged(w, h, 0); SCR_ModeChanged(); }
        Com_Printf("xr3: stereo OFF\n");
    }
}

// Per-eye begin (engine thread): stereo matrices + this eye's FBO as the default framebuffer.
void VID_iOS_XR3_BeginEye(int eye, float halfSep, float convergence) {
    if (!q2_xr3_mode) return;
    GLuint fbo = xr3_wrap(eye & 1);
    if (!fbo) return;
    V_SetStereoConvergence(convergence);
    V_SetStereoOffset(eye == 0 ? -halfSep : +halfSep);
    R_SetDefaultFramebuffer(fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
}

// After both eyes: zero the offset and fence ANGLE's GPU work with a shared event the
// compositor waits on before sampling the textures.
void VID_iOS_XR3_EndFrame(void) {
    if (!q2_xr3_mode) return;
    V_SetStereoOffset(0);
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return;
    EGLSync sync = eglCreateSync(dpy, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, NULL);
    if (sync == EGL_NO_SYNC) return;
    glFlush();
    void *evt = eglCopyMetalSharedEventANGLE(dpy, sync);
    EGLAttrib lo = 0, hi = 0;
    eglGetSyncAttrib(dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, &lo);
    eglGetSyncAttrib(dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, &hi);
    s_signal = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
    eglDestroySync(dpy, sync);
    s_event = (__bridge_transfer id<MTLSharedEvent>)evt;
    s_framesRendered++;
}

// Consumer thread: the compositor's command buffer waits on the engine's stereo fence.
void VID_iOS_XR3_WaitOn(void *cmdBuffer) {
    id<MTLSharedEvent> e = s_event;
    if (e) [(__bridge id<MTLCommandBuffer>)cmdBuffer encodeWaitForEvent:e value:s_signal];
}

#endif // Q2_XR_UI
