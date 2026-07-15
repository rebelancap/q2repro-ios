// xr_render.m — immersive (visionOS 3D) ANGLE video driver.
// Replaces vid_angle.m in the Q2_VISIONOS_3D variant. Instead of presenting to a CAMetalLayer
// window, the engine renders into the compositor drawable's per-eye Metal textures: we point the
// renderer's default framebuffer (R_SetDefaultFramebuffer) at an FBO wrapping the eye texture
// via ANGLE's EGL_ANGLE_metal_texture_client_buffer, and a Compositor Services loop (the Swift
// shell) drives Qcommon_Frame per eye and presents. Same ANGLE substrate as the 2D build.
#if defined(Q2_USE_ANGLE) && Q2_USE_ANGLE

// NOTE: do NOT import <UIKit/UIKit.h> here — it transitively pulls in the system OpenGLES
// module (UIKit→CoreImage→CoreVideo→OpenGLES), whose GL prototypes are marked *unavailable* on
// visionOS and shadow ANGLE's. Foundation + Metal are enough; ANGLE's GLES headers below own the
// GL symbols. (The 2D vid_angle.m can import UIKit only because it never includes GLES3/gl3.h.)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dlfcn.h>
#import <os/lock.h>
#include <stdio.h>

#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/zone.h"
#include "common/cmd.h"
#include "client/video.h"
#include "refresh/refresh.h"

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
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
static int s_width = 1920, s_height = 1824;   // per-eye; updated when the first drawable arrives

// --- shared app glue (same API as vid_angle.m; only one of them compiles) -----
// Ring buffer of the engine's console output — device logs are unreadable here (devicectl 7000),
// so we surface the tail in the launcher window to see boot/map-load results directly.
static char       s_con[8000];
static size_t     s_conlen;
static os_unfair_lock s_conlk = OS_UNFAIR_LOCK_INIT;
const char *VID_iOS_XR_ConsoleTail(void) { return s_con; }   // racy but fine for a diagnostic

void Sys_ConsoleOutput(const char *text, size_t len) {
    fwrite(text, 1, len, stderr); fflush(stderr);
    static FILE *lf; static int tried;
    if (!lf && !tried) { tried = 1;
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                       stringByAppendingPathComponent:@"qconsole.log"];
        lf = fopen(p.fileSystemRepresentation, "w"); }
    if (lf) { fwrite(text, 1, len, lf); fflush(lf); }

    os_unfair_lock_lock(&s_conlk);
    if (len > sizeof(s_con) - 1) { text += len - (sizeof(s_con) - 1); len = sizeof(s_con) - 1; }
    if (s_conlen + len > sizeof(s_con) - 1) {                 // keep the tail
        size_t drop = s_conlen + len - (sizeof(s_con) - 1);
        memmove(s_con, s_con + drop, s_conlen - drop);
        s_conlen -= drop;
    }
    memcpy(s_con + s_conlen, text, len); s_conlen += len; s_con[s_conlen] = 0;
    os_unfair_lock_unlock(&s_conlk);
}
void VID_iOS_SetLayer(void *layer) { (void)layer; }   // no window layer in immersive
void VID_iOS_RequestCapture(const char *path) { (void)path; }
static float s_look_dx, s_look_dy;
void VID_iOS_AddLook(float dx, float dy) { s_look_dx += dx; s_look_dy += dy; }
void VID_iOS_Command(const char *cmd) { Cmd_ExecuteString(&cmd_buffer, cmd); }
void VID_iOS_Resize(void) {}   // immersive has no resizable window

// --- ANGLE init (surfaceless — we render into FBOs wrapping drawable textures) -
static bool a_probe(void) { return true; }

static bool a_init(void) {
    const EGLint dattr[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    s_dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
    if (s_dpy == EGL_NO_DISPLAY) { Com_EPrintf("xr: no display\n"); return false; }
    EGLint major, minor;
    if (!eglInitialize(s_dpy, &major, &minor)) { Com_EPrintf("xr: eglInitialize 0x%x\n", eglGetError()); return false; }
    Com_Printf("xr: ANGLE %s (EGL %d.%d)\n", eglQueryString(s_dpy, EGL_VENDOR), major, minor);

    const EGLint cfga[] = { EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                            EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
                            EGL_DEPTH_SIZE,24, EGL_STENCIL_SIZE,8, EGL_NONE };
    EGLint n = 0;
    if (!eglChooseConfig(s_dpy, cfga, &s_cfg, 1, &n) || n < 1) { Com_EPrintf("xr: no config\n"); return false; }
    const EGLint ctxa[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
    s_ctx = eglCreateContext(s_dpy, s_cfg, EGL_NO_CONTEXT, ctxa);
    if (s_ctx == EGL_NO_CONTEXT) { Com_EPrintf("xr: no ES3 context 0x%x\n", eglGetError()); return false; }
    if (!eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s_ctx)) {
        Com_EPrintf("xr: surfaceless makeCurrent 0x%x\n", eglGetError()); return false;
    }
    Com_Printf("xr: ES3 context created (surfaceless)\n");
    return true;
}
static void a_shutdown(void) {
    if (s_dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (s_ctx != EGL_NO_CONTEXT) eglDestroyContext(s_dpy, s_ctx);
        eglTerminate(s_dpy);
        s_dpy = EGL_NO_DISPLAY; s_ctx = EGL_NO_CONTEXT;
    }
}
static void a_set_mode(void) { R_ModeChanged(s_width, s_height, 0); SCR_ModeChanged(); }
static char *a_get_mode_list(void) { char b[64]; Q_snprintf(b, sizeof b, "%dx%d", s_width, s_height); return Z_CopyString(b); }
static int   a_get_dpi_scale(void) { return 1; }
static void  a_update_gamma(const byte *t) { (void)t; }
static void *a_get_proc_addr(const char *s) { return (void *)eglGetProcAddress(s); }
// The Compositor Services loop owns present; the engine's per-frame "swap" just flushes GL.
static void  a_swap_buffers(void) { glFlush(); }
static void  a_swap_interval(int v) { (void)v; }
static char *a_sel(void) { return NULL; }
static char *a_clip(void) { return NULL; }
static void  a_setclip(const char *d) { (void)d; }
static bool  a_init_mouse(void) { return true; }
static void  a_shutdown_mouse(void) {}
static void  a_grab(bool g) { (void)g; }
static void  a_warp(int x, int y) { (void)x; (void)y; }
static bool  a_motion(int *dx, int *dy) {
    *dx = (int)lrintf(s_look_dx); *dy = (int)lrintf(s_look_dy);
    s_look_dx -= *dx; s_look_dy -= *dy; return (*dx || *dy);
}
static void  a_pump(void) {}

const vid_driver_t vid_angle = {
    .name = "angle", .probe = a_probe, .init = a_init, .shutdown = a_shutdown, .fatal_shutdown = a_shutdown,
    .pump_events = a_pump, .get_mode_list = a_get_mode_list, .get_dpi_scale = a_get_dpi_scale, .set_mode = a_set_mode,
    .update_gamma = a_update_gamma, .get_proc_addr = a_get_proc_addr, .swap_buffers = a_swap_buffers, .swap_interval = a_swap_interval,
    .get_selection_data = a_sel, .get_clipboard_data = a_clip, .set_clipboard_data = a_setclip,
    .init_mouse = a_init_mouse, .shutdown_mouse = a_shutdown_mouse, .grab_mouse = a_grab, .warp_mouse = a_warp, .get_mouse_motion = a_motion,
};

// ================= Immersive interface (called by the Compositor Services shell) =============

// Wrap a slice of a compositor drawable texture (a texture 2D array) as a GL FBO, cached by
// (texture pointer, slice). Returns the GL FBO id (0 on failure). Each FBO gets its OWN depth
// renderbuffer: the engine's 3D pass needs a real z-buffer, and without one the scene z-fights —
// holes punched through geometry and the viewmodel (gun) drawing through itself. Sized to the
// texture; recreated when a cache slot is reused for a differently-sized texture.
#define XR_MAX_WRAPS 16
static struct { void *tex; int slice; int w, h; EGLImageKHR img; GLuint glTex, fbo, depthRb; } s_wraps[XR_MAX_WRAPS];
static int s_wrapCount;

static void xr_free_wrap(int i) {
    eglDestroyImageKHR(s_dpy, s_wraps[i].img);
    glDeleteTextures(1, &s_wraps[i].glTex);
    glDeleteRenderbuffers(1, &s_wraps[i].depthRb);
    glDeleteFramebuffers(1, &s_wraps[i].fbo);
}

static GLuint xr_wrap(id<MTLTexture> tex, int slice) {
    void *p = (__bridge void *)tex;
    for (int i = 0; i < s_wrapCount; i++) if (s_wraps[i].tex == p && s_wraps[i].slice == slice) return s_wraps[i].fbo;
    // The compositor rotates drawable textures (swapchain), so new (tex,slice) pairs appear over
    // time. When the cache fills, EVICT THE OLDEST (FIFO) and free its resources — never return 0,
    // which in a surfaceless context is a non-existent framebuffer, so the engine draws nowhere
    // (the bug that made every frame black once >XR_MAX_WRAPS unique textures had been seen).
    if (s_wrapCount >= XR_MAX_WRAPS) {
        xr_free_wrap(0);
        memmove(&s_wraps[0], &s_wraps[1], sizeof(s_wraps[0]) * (XR_MAX_WRAPS - 1));
        s_wrapCount--;
    }
    const EGLint attribs[] = { EGL_METAL_TEXTURE_ARRAY_SLICE_ANGLE, slice, EGL_NONE };
    EGLImageKHR img = eglCreateImageKHR(s_dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE, (EGLClientBuffer)p, attribs);
    if (img == EGL_NO_IMAGE_KHR) { Com_EPrintf("xr: no EGLImage 0x%x\n", eglGetError()); return 0; }
    GLuint glTex = 0, fbo = 0, depthRb = 0;
    glGenTextures(1, &glTex); glBindTexture(GL_TEXTURE_2D, glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTex, 0);
    // Depth+stencil renderbuffer matching the eye texture — the engine renders a 3D world here and
    // must z-test (and the refresh uses stencil for a few effects). Without it: z-fighting/holes.
    glGenRenderbuffers(1, &depthRb); glBindRenderbuffer(GL_RENDERBUFFER, depthRb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)tex.width, (GLsizei)tex.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, depthRb);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { Com_EPrintf("xr: FBO incomplete\n"); }
    int idx = s_wrapCount++;
    s_wraps[idx].tex = p; s_wraps[idx].slice = slice; s_wraps[idx].w = (int)tex.width; s_wraps[idx].h = (int)tex.height;
    s_wraps[idx].img = img; s_wraps[idx].glTex = glTex; s_wraps[idx].fbo = fbo; s_wraps[idx].depthRb = depthRb;
    return fbo;
}

// Point the engine's default framebuffer at the given drawable slice; the next Qcommon_Frame
// renders the whole game into it. Also updates the render size if it changed.
static GLuint s_lastFBO;
int VID_iOS_XR_LastFBO(void) { return (int)s_lastFBO; }

void VID_iOS_XR_SetEye(id<MTLTexture> tex, int slice, int w, int h) {
    GLuint fbo = xr_wrap(tex, slice);
    s_lastFBO = fbo;
    R_SetDefaultFramebuffer(fbo);
    // Set the VALUE (above) AND actually bind it as the current render target, so the engine's
    // R_BeginFrame (which does not bind default_framebuffer itself — overlay 0003 only redirects
    // the FBO-return sites) draws into our eye FBO instead of framebuffer 0, which is nothing on a
    // surfaceless context. This is what the EAGL driver's swap_buffers does (vid_ios.m:184).
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    if (w != s_width || h != s_height) { s_width = w; s_height = h; R_ModeChanged(w, h, 0); }
}

// Copy the rendered eye 0 into eye 1 (mono → both eyes) via a GL blit (both on ANGLE's queue).
void VID_iOS_XR_BlitEyes(id<MTLTexture> tex, int fromSlice, int toSlice, int w, int h) {
    GLuint src = xr_wrap(tex, fromSlice), dst = xr_wrap(tex, toSlice);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, src);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

// Cross-queue sync: fence ANGLE's work; the present command buffer waits on the shared event.
static id<MTLSharedEvent> s_event;
static uint64_t s_signalValue;
void VID_iOS_XR_MakeSync(void) {
    if (s_dpy == EGL_NO_DISPLAY) return;
    EGLSync sync = eglCreateSync(s_dpy, EGL_SYNC_METAL_SHARED_EVENT_ANGLE, NULL);
    if (sync == EGL_NO_SYNC) return;
    glFlush();
    void *evt = eglCopyMetalSharedEventANGLE(s_dpy, sync);
    EGLAttrib lo = 0, hi = 0;
    eglGetSyncAttrib(s_dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE, &lo);
    eglGetSyncAttrib(s_dpy, sync, EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE, &hi);
    s_signalValue = ((uint64_t)(uint32_t)hi << 32) | (uint32_t)lo;
    eglDestroySync(s_dpy, sync);
    s_event = (__bridge_transfer id<MTLSharedEvent>)evt;
}
void VID_iOS_XR_WaitOn(id<MTLCommandBuffer> cmd) {
    if (s_event) [cmd encodeWaitForEvent:s_event value:s_signalValue];
}

// CPU-block until ALL of ANGLE's queued Metal work (engine render + eye blit) has actually
// completed on the GPU. The shared-event fence above proved insufficient in Spike B; the proven
// path (spike b728946, which showed blue) used a hard glFinish before the compositor read the
// texture. Heavy, but correct for M1 — replace with a real GPU fence once pixels are confirmed.
void VID_iOS_XR_Finish(void) { glFinish(); }

// Read the center pixel of the given eye slice's FBO after the engine frame — average brightness
// scaled by 1000, for the on-screen diagnostic. >0 ⇒ the engine wrote non-black pixels into the
// eye texture (so any remaining blackness is a present/composite problem, not a render one).
int VID_iOS_XR_ProbeLuma(id<MTLTexture> tex, int slice) {
    GLuint fbo = xr_wrap(tex, slice);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, fbo);
    // Sample a 5×5 grid and take the brightest — a single center pixel can sit on a dark spot
    // even when the scene renders. >0 ⇒ the engine wrote SOMETHING into this eye texture.
    int maxv = 0;
    for (int gy = 1; gy <= 5; gy++) for (int gx = 1; gx <= 5; gx++) {
        GLfloat px[4] = {0, 0, 0, 0};
        glReadPixels((GLint)(tex.width * gx / 6), (GLint)(tex.height * gy / 6), 1, 1, GL_RGBA, GL_FLOAT, px);
        int v = (int)((px[0] + px[1] + px[2]) * 1000.0f / 3.0f);
        if (v > maxv) maxv = v;
    }
    glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    return maxv;
}

#endif // Q2_USE_ANGLE
