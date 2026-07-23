// xr3_glue.m — stereo machinery for the MERGED visionOS 2D+3D app (Q2_XR_UI).
// UIKit-free on purpose: UIKit transitively imports the system OpenGLES module, whose GL
// prototypes are marked unavailable on visionOS and shadow ANGLE's (the xr_render.m trap).
// Foundation + Metal + ANGLE's GLES headers own the GL symbols here.
//
// Shape (SoH D-036 producer architecture, adapted to ANGLE): the engine renders both eyes
// per tick (main thread, ANGLE) into PING-PONG Metal textures wrapped as GL FBOs; a frame
// is PUBLISHED to the compositor only when its GPU work completes (shared-event listener),
// so the SwiftUI consumer never samples a texture the engine is still writing. The old
// single-buffer + forward-fence design was the device stall/edge-warp bug: producer and
// consumer couldn't pipeline, and the engine overwrote mip 0 mid-sample.
#if defined(Q2_XR_UI) && Q2_XR_UI

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdatomic.h>
#include <unistd.h>

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

// Eye buffer ring: [eye][buf], XR3_EYE_BUFS deep. The engine renders both eyes into
// buf s_ping each tick; on GPU completion the pair is published (s_pub) and s_ping
// advances. RGBA8 (engine GL output is 8-bit anyway; 16F doubled every byte of
// bandwidth for nothing) and NOT mipmapped — the compositor mip-chains its own
// private copy (SoH parity). THREE buffers, not two: publish-on-completion has no
// cross-queue fence, so the compositor may still be blit-copying publish N when the
// engine starts frame N+2 — with a 2-deep ring that is the SAME texture (the
// fast-producer reuse race); 3-deep gives the copy a full ring turn of margin.
#define XR3_EYE_BUFS 3
static struct {
    void *mtl;               // retained MTLTexture (via CFBridgingRetain)
    EGLImageKHR img;
    GLuint glTex, fbo;
    int w, h;
    bool wrapped;
} s_buf[2][XR3_EYE_BUFS];

static int s_ping;                        // engine thread only
static _Atomic(void *) s_pub[2];          // last GPU-completed pair (compositor reads)
static atomic_int s_framesRendered;       // PUBLISHED stereo frames since entering 3D
static atomic_int s_inFlight;             // submitted-but-not-GPU-complete engine frames
static MTLSharedEventListener *s_listener;

// One shared depth-stencil renderbuffer: the engine renders eyes/buffers sequentially,
// so all four FBOs can share it. (Real z-buffer required — without it the scene
// z-fights: holes, the viewmodel drawing through itself.)
static GLuint s_depthRb;
static int s_depthW, s_depthH;

bool VID_iOS_XR3_SetEyeTexture2(int eye, int buf, void *mtlTexture) {
    if (eye < 0 || eye > 1 || buf < 0 || buf >= XR3_EYE_BUFS || !mtlTexture) return false;
    if (s_buf[eye][buf].mtl == mtlTexture) return true;
    if (s_buf[eye][buf].mtl) CFRelease(s_buf[eye][buf].mtl);
    s_buf[eye][buf].mtl = (void *)CFRetain(mtlTexture);
    s_buf[eye][buf].wrapped = false;    // (re)wrap lazily on the engine thread
    id<MTLTexture> t = (__bridge id<MTLTexture>)mtlTexture;
    s_buf[eye][buf].w = (int)t.width; s_buf[eye][buf].h = (int)t.height;
    return true;
}

static GLuint xr3_shared_depth(int w, int h) {
    if (s_depthRb && s_depthW == w && s_depthH == h) return s_depthRb;
    if (s_depthRb) glDeleteRenderbuffers(1, &s_depthRb);
    glGenRenderbuffers(1, &s_depthRb); glBindRenderbuffer(GL_RENDERBUFFER, s_depthRb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, w, h);
    s_depthW = w; s_depthH = h;
    return s_depthRb;
}

// Engine thread only (ANGLE context current). Returns the FBO id or 0.
static GLuint xr3_wrap(int eye, int buf) {
    if (s_buf[eye][buf].wrapped) return s_buf[eye][buf].fbo;
    if (!s_buf[eye][buf].mtl) return 0;
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return 0;
    if (s_buf[eye][buf].img) {          // free a previous wrap (texture was replaced)
        eglDestroyImageKHR(dpy, s_buf[eye][buf].img);
        glDeleteTextures(1, &s_buf[eye][buf].glTex);
        glDeleteFramebuffers(1, &s_buf[eye][buf].fbo);
        s_buf[eye][buf].img = NULL;
    }
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)s_buf[eye][buf].mtl, NULL);
    if (img == EGL_NO_IMAGE_KHR) { Com_EPrintf("xr3: no EGLImage 0x%x\n", eglGetError()); return 0; }
    GLuint glTex = 0, fbo = 0;
    glGenTextures(1, &glTex); glBindTexture(GL_TEXTURE_2D, glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTex, 0);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                              xr3_shared_depth(s_buf[eye][buf].w, s_buf[eye][buf].h));
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE) { Com_EPrintf("xr3: eye FBO incomplete 0x%x\n", st); return 0; }
    s_buf[eye][buf].img = img; s_buf[eye][buf].glTex = glTex; s_buf[eye][buf].fbo = fbo;
    s_buf[eye][buf].wrapped = true;
    return fbo;
}

int VID_iOS_XR3_Active(void) { return q2_xr3_mode; }

// The glue OWNS the eye textures and creates them on demand — BEFORE the immersive space
// opens (Q2_XR3_EngineEnter3D → SetMode runs first). Creating them in the panel renderer
// was the black-first-entry bug: on the first entry SetMode found no textures and failed,
// the engine kept rendering to the window, and the panel sampled never-written memory.
static void xr3_target_size(int *w, int *h);
static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace);
static void xr3_ensure_textures(void) {
    for (int e = 0; e < 2; e++) for (int b = 0; b < XR3_EYE_BUFS; b++)
        if (!s_buf[e][b].mtl) goto create;
    return;
create:;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    int w = 0, h = 0; xr3_target_size(&w, &h);
    xr3_make_textures(dev, w, h, false);
}

// Render size = the panel's ASPECT at a quality-scaled pixel budget (vkQuake's formula:
// w = sqrt(budget * aspect)). The render always matches the panel shape 1:1 — a
// mismatched aspect stretches the image (the 4:3-onto-16:9 "fat geometry" bug),
// and this is what makes ultra-widescreen panels render true Hor+ widescreen.
// xr_quality scales the ~8.3 MP vkQuake budget: that number was inherited from a
// fenced Vulkan Q1 engine; Q2-rerelease-through-ANGLE frames are far heavier, and
// 100% can exceed what the GPU sustains at engine rate (FOVEATION-PERF-CONSULT.md).
static void xr3_target_size(int *w, int *h) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    float halfW = [d objectForKey:@"xr_halfW"] ? (float)[d floatForKey:@"xr_halfW"] : 2.75f;
    float halfH = [d objectForKey:@"xr_halfH"] ? (float)[d floatForKey:@"xr_halfH"] : 1.55f;
    float aspect = (halfH > 0.01f) ? (halfW / halfH) : (16.0f / 9.0f);
    if (aspect < 0.5f) aspect = 0.5f;
    if (aspect > 4.0f) aspect = 4.0f;   // sane clamp (extreme shapes explode one dimension)
    float q = [d objectForKey:@"xr_quality"] ? (float)[d floatForKey:@"xr_quality"] : 0.6f;   // 60% = locked 120/120 on device
    if (q < 0.35f) q = 0.35f;
    if (q > 1.0f) q = 1.0f;
    const float budget = 3840.0f * 2160.0f * q;
    float fw = sqrtf(budget * aspect);
    *w = ((int)lroundf(fw) + 7) & ~7;           // multiple of 8
    *h = ((int)lroundf(fw / aspect) + 7) & ~7;
}

static int s_eyeGeneration;
static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    for (int e = 0; e < 2; e++) for (int b = 0; b < XR3_EYE_BUFS; b++) if (replace || !s_buf[e][b].mtl) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (t) VID_iOS_XR3_SetEyeTexture2(e, b, (__bridge void *)t);
    }
    // Nothing published at the new size yet — the consumer draws dim-only until a
    // completed frame lands (it retains whatever it fetched for the in-flight frame).
    atomic_store(&s_pub[0], NULL);
    atomic_store(&s_pub[1], NULL);
    atomic_store(&s_framesRendered, 0);
    s_eyeGeneration++;
}

int VID_iOS_XR3_EyeGeneration(void) { return s_eyeGeneration; }

// Re-sync the render size to the panel's current aspect (slider release / entry). Engine
// thread only. No-op within 16 px (vkQuake's threshold) or when textures don't exist yet.
void VID_iOS_XR3_ResizeEyes(void) {
    if (!s_buf[0][0].mtl) return;
    int w = 0, h = 0; xr3_target_size(&w, &h);
    if (abs(w - s_buf[0][0].w) <= 16 && abs(h - s_buf[0][0].h) <= 16) return;
    xr3_make_textures(MTLCreateSystemDefaultDevice(), w, h, true);
    if (q2_xr3_mode) {      // engine renders the new aspect immediately (Hor+ FOV)
        R_ModeChanged(w, h, 0);
        SCR_ModeChanged();
        Com_Printf("xr3: render re-synced to %dx%d\n", w, h);
    }
}
// The compositor reads the last PUBLISHED (GPU-complete) texture — never the one the
// engine is rendering into. NULL until the first completed frame at the current size.
void *VID_iOS_XR3_EyeTexture(int eye) { return atomic_load(&s_pub[eye & 1]); }
int VID_iOS_XR3_FramesRendered(void) { return atomic_load(&s_framesRendered); }
int VID_iOS_XR3_InFlight(void) { return atomic_load(&s_inFlight); }

// Enter/leave stereo (engine thread). On enter the engine's render size becomes the eye
// texture size; on exit it returns to the window surface size. Window never touched in 3D.
void VID_iOS_XR3_SetMode(int on) {
    if (q2_xr3_mode == !!on) return;
    if (on) xr3_ensure_textures();
    if (on && (!s_buf[0][0].mtl || !s_buf[1][0].mtl)) { Com_EPrintf("xr3: no eye textures\n"); return; }
    q2_xr3_mode = !!on;
    if (on) {
        // Panel draws passthrough-only until a fresh frame publishes.
        atomic_store(&s_pub[0], NULL);
        atomic_store(&s_pub[1], NULL);
        atomic_store(&s_framesRendered, 0);
        atomic_store(&s_inFlight, 0);
        s_ping = 0;
        R_ModeChanged(s_buf[0][0].w, s_buf[0][0].h, 0);
        SCR_ModeChanged();
        Com_Printf("xr3: stereo ON (%dx%d per eye, ring-%d, max 2 in flight)\n",
                   s_buf[0][0].w, s_buf[0][0].h, XR3_EYE_BUFS);
    } else {
        V_SetStereoOffset(0);
        R_SetDefaultFramebuffer(0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        int w = 0, h = 0; VID_iOS_XR3_GetWindowSize(&w, &h);
        if (w && h) { R_ModeChanged(w, h, 0); SCR_ModeChanged(); }
        Com_Printf("xr3: stereo OFF\n");
    }
}

// Per-eye begin (engine thread): stereo matrices + this eye's CURRENT PING FBO as the
// default framebuffer. Eye 0 first applies the frames-in-flight bound: never start a
// new stereo frame while 2 are still on the GPU (vkQuake's vkWaitForFences discipline,
// which the 3D path lost when it gated off eglSwapBuffers — ANGLE's only built-in
// backpressure). Without this the display link free-runs the producer and the command
// queue grows without bound: seconds of latency, hitching, GPU saturation, jetsam.
void VID_iOS_XR3_BeginEye(int eye, float halfSep, float convergence) {
    if (!q2_xr3_mode) return;
    if (eye == 0 && atomic_load(&s_inFlight) >= 2) {
        int spins = 0;
        while (atomic_load(&s_inFlight) >= 2 && ++spins < 400) usleep(500);   // ≤200 ms
        if (spins >= 400) {   // GPU wedged or a completion was lost — self-heal, loudly
            Com_EPrintf("xr3: in-flight gate timed out, resetting\n");
            atomic_store(&s_inFlight, 0);
        }
    }
    GLuint fbo = xr3_wrap(eye & 1, s_ping);
    if (!fbo) return;
    V_SetStereoConvergence(convergence);
    V_SetStereoOffset(eye == 0 ? -halfSep : +halfSep);
    R_SetDefaultFramebuffer(fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
}

// After both eyes: publish this frame's buffer pair WHEN ITS GPU WORK COMPLETES (shared-
// event listener), then advance the ring so the next engine frame writes another pair.
// The compositor consumes only published pairs — no cross-queue fence needed, and the
// engine's next frame can overlap the compositor's sampling of the previous one.
// Each scheduled completion counts against the in-flight bound (BeginEye eye 0 waits).
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
    uint64_t value = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
    eglDestroySync(dpy, sync);
    id<MTLSharedEvent> event = (__bridge_transfer id<MTLSharedEvent>)evt;
    if (!event) return;
    if (!s_listener) {
        s_listener = [[MTLSharedEventListener alloc]
            initWithDispatchQueue:dispatch_queue_create("q2.xr3.publish", DISPATCH_QUEUE_SERIAL)];
    }
    void *p0 = s_buf[0][s_ping].mtl, *p1 = s_buf[1][s_ping].mtl;
    atomic_fetch_add(&s_inFlight, 1);
    [event notifyListener:s_listener atValue:value
                    block:^(id<MTLSharedEvent> e, uint64_t v) {
        (void)e; (void)v;   // block retains the event until it fires
        atomic_store(&s_pub[0], p0);
        atomic_store(&s_pub[1], p1);
        atomic_fetch_add(&s_framesRendered, 1);
        atomic_fetch_sub(&s_inFlight, 1);
    }];
    s_ping = (s_ping + 1) % XR3_EYE_BUFS;
}

#endif // Q2_XR_UI
