// vid_angle.m — ANGLE (ES on Metal) video driver, EGL on a CAMetalLayer.
// Phase-3 perf experiment: does moving off Apple's deprecated GLES-over-Metal
// (which makes per-draw UBO uploads expensive) restore 60fps WITH full lighting?
// Active only when Q2_USE_ANGLE is defined; vid_ios.m is the EAGL counterpart.
#if defined(Q2_USE_ANGLE) && Q2_USE_ANGLE

#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <dlfcn.h>
#include <stdio.h>

#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>


#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/zone.h"
#include "common/cmd.h"
#include "client/video.h"
#include "refresh/refresh.h"

extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a]

#ifndef EGL_PLATFORM_ANGLE_ANGLE
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#endif
#ifndef EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE
#define EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE 0x3489
#endif

// Declared in inc/client/client.h, which this file does not include (it drags the whole
// client in). Without the prototype clang treats the call as an implicit declaration —
// caught by scripts/ios-syntax-check.sh / vr-syntax-check.sh.
extern void SCR_ModeChanged(void);

#if defined(Q2_XR_UI) && Q2_XR_UI
extern int q2_xr3_mode;            // xr3_glue.m: 1 while the engine renders the stereo eyes
#endif
static CALayer   *s_layer;         // CAMetalLayer, set before Qcommon_Init
static EGLDisplay s_dpy = EGL_NO_DISPLAY;
static EGLContext s_ctx = EGL_NO_CONTEXT;
static EGLSurface s_surf = EGL_NO_SURFACE;
static EGLConfig  s_cfg;
static int s_width, s_height, s_scale = 1;

// --- shared app glue (same API as vid_ios.m; only one file compiles) ---------
void Sys_ConsoleOutput(const char *text, size_t len) {
    fwrite(text, 1, len, stderr); fflush(stderr);
    static FILE *lf; static int tried;
    if (!lf && !tried) { tried = 1;
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                       stringByAppendingPathComponent:@"qconsole.log"];
        lf = fopen(p.fileSystemRepresentation, "w"); }
    if (lf) { fwrite(text, 1, len, lf); fflush(lf); }
}
void VID_iOS_SetLayer(void *layer) { s_layer = (__bridge CALayer *)layer; }
void VID_iOS_RequestCapture(const char *path) { (void)path; }   // not needed for the perf run
static float s_look_dx, s_look_dy;
void VID_iOS_AddLook(float dx, float dy) { s_look_dx += dx; s_look_dy += dy; }
// Console commands from the shell. While a dedicated engine thread owns the frame (VR),
// Cmd_ExecuteString would run arbitrary engine code on whatever thread called us — the
// settings sheet's MainActor, a scene handler, a UIKit gesture. Route through the producer
// funnel in ios_bridge.m, which executes it at the top of the next engine frame in order.
extern int  Q2_iOS_ShouldDefer(void);
extern void Q2_iOS_QueueCommand(const char *cmd);
void VID_iOS_Command(const char *cmd) {
    if (Q2_iOS_ShouldDefer()) { Q2_iOS_QueueCommand(cmd); return; }
    Cmd_ExecuteString(&cmd_buffer, cmd);
}

// --- vid_driver_t ------------------------------------------------------------
static bool a_probe(void) { return true; }

// Pin the drawable to sRGB. On a wide-gamut (Display P3) iPhone panel, a CAMetalLayer with
// no explicit colorspace stretches the engine's sRGB output across P3 → oversaturated colors.
// ANGLE resets the layer when it (re)creates the window surface, so re-apply after each
// eglCreateWindowSurface, not just once at init.
// Pin the drawable to sRGB (correct on the wide-gamut panel; matches the desktop oracle).
static void a_force_srgb(void) {
    if (![s_layer isKindOfClass:[CAMetalLayer class]]) return;
    CAMetalLayer *ml = (CAMetalLayer *)s_layer;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    ml.colorspace = cs;
    // Guarded: the deployment target is iOS 15, where this selector does not exist
    // (unrecognized-selector crash). Off is the default there anyway, so nothing is lost.
    if (@available(iOS 16.0, visionOS 1.0, *)) ml.wantsExtendedDynamicRangeContent = NO;
    CGColorSpaceRelease(cs);
}

static bool a_init(void) {
    if (!s_layer) { Com_EPrintf("vid_angle: no layer\n"); return false; }
    s_scale = (int)lrintf((float)s_layer.contentsScale); if (s_scale < 1) s_scale = 1;
    a_force_srgb();

    EGLint dattr[] = { EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE };
    s_dpy = eglGetPlatformDisplayEXT(EGL_PLATFORM_ANGLE_ANGLE, (void *)EGL_DEFAULT_DISPLAY, dattr);
    if (s_dpy == EGL_NO_DISPLAY) { Com_EPrintf("vid_angle: no display\n"); return false; }
    EGLint major, minor;
    if (!eglInitialize(s_dpy, &major, &minor)) { Com_EPrintf("vid_angle: eglInitialize 0x%x\n", eglGetError()); return false; }
    Com_Printf("vid_angle: ANGLE %s (EGL %d.%d)\n", eglQueryString(s_dpy, EGL_VENDOR), major, minor);

    EGLint cfga[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT,
                      EGL_RED_SIZE,8, EGL_GREEN_SIZE,8, EGL_BLUE_SIZE,8, EGL_ALPHA_SIZE,8,
                      EGL_DEPTH_SIZE,24, EGL_STENCIL_SIZE,8, EGL_NONE };
    EGLint n = 0;
    if (!eglChooseConfig(s_dpy, cfga, &s_cfg, 1, &n) || n < 1) { Com_EPrintf("vid_angle: no config\n"); return false; }

    EGLint ctxa[] = { EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, 0, EGL_NONE };
    s_ctx = eglCreateContext(s_dpy, s_cfg, EGL_NO_CONTEXT, ctxa);
    if (s_ctx == EGL_NO_CONTEXT) { Com_EPrintf("vid_angle: no ES3 context 0x%x\n", eglGetError()); return false; }
    // Make current surfaceless so QGL_Init (which runs before set_mode) can query GL_VERSION.
    if (!eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, s_ctx)) {
        Com_EPrintf("vid_angle: surfaceless makeCurrent failed 0x%x\n", eglGetError()); return false;
    }
    Com_Printf("vid_angle: ES3 context created (scale %d)\n", s_scale);
    return true;   // window surface built in set_mode
}

static void a_shutdown(void) {
    if (s_dpy != EGL_NO_DISPLAY) {
        eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (s_surf != EGL_NO_SURFACE) eglDestroySurface(s_dpy, s_surf);
        if (s_ctx != EGL_NO_CONTEXT) eglDestroyContext(s_dpy, s_ctx);
        eglTerminate(s_dpy);
        s_dpy = EGL_NO_DISPLAY; s_ctx = EGL_NO_CONTEXT; s_surf = EGL_NO_SURFACE;
    }
}

static void a_set_mode(void) {
    if (s_surf != EGL_NO_SURFACE) { eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT); eglDestroySurface(s_dpy, s_surf); s_surf = EGL_NO_SURFACE; }
    s_surf = eglCreateWindowSurface(s_dpy, s_cfg, (EGLNativeWindowType)(__bridge void *)s_layer, NULL);
    if (s_surf == EGL_NO_SURFACE) { Com_EPrintf("vid_angle: no window surface 0x%x\n", eglGetError()); SCR_ModeChanged(); return; }
    eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx);
    eglQuerySurface(s_dpy, s_surf, EGL_WIDTH, &s_width);
    eglQuerySurface(s_dpy, s_surf, EGL_HEIGHT, &s_height);
    R_ModeChanged(s_width, s_height, 0);   // ANGLE window surface = default framebuffer 0
    SCR_ModeChanged();
}

// Window resized — visionOS windows are user-resizable (the iOS window is fixed-fullscreen,
// so this never fired there). Resize the Metal drawable to the new bounds×scale and rebuild
// the ANGLE window surface + renderer viewport; otherwise the grown region shows an empty
// (black) drawable. Called from the view's layoutSubviews on the main thread (same thread as
// the display link, so no GL-context races).
void VID_iOS_Resize(void) {
#if defined(Q2_XR_UI) && Q2_XR_UI
    // In 3D the window is parked as a small card: its resize must NOT rebuild the EGL
    // window surface or touch the engine's render size (the eyes render offscreen). The
    // restore-resize on exit re-runs this after stereo mode is off and syncs everything.
    if (q2_xr3_mode) return;
#endif
    if (s_dpy == EGL_NO_DISPLAY || s_ctx == EGL_NO_CONTEXT || !s_layer) return;
    if (![s_layer isKindOfClass:[CAMetalLayer class]]) return;
    CGFloat sc = s_layer.contentsScale; if (sc < 1) sc = 1;
    CGSize px = CGSizeMake(s_layer.bounds.size.width * sc, s_layer.bounds.size.height * sc);
    if (px.width < 1 || px.height < 1) return;
    if ((int)px.width == s_width && (int)px.height == s_height) return;   // no real change
    ((CAMetalLayer *)s_layer).drawableSize = px;
    a_set_mode();
}

static char *a_get_mode_list(void) {
    int w = s_width ? s_width : (int)(s_layer.bounds.size.width * s_layer.contentsScale);
    int h = s_height ? s_height : (int)(s_layer.bounds.size.height * s_layer.contentsScale);
    char buf[64]; Q_snprintf(buf, sizeof buf, "%dx%d", w ? w : 1280, h ? h : 720);
    return Z_CopyString(buf);
}
static int   a_get_dpi_scale(void) { return s_scale; }
static void  a_update_gamma(const byte *t) { (void)t; }
static void *a_get_proc_addr(const char *s) { return (void *)eglGetProcAddress(s); }
// Re-pin sRGB every frame: iOS/ANGLE can reset the CAMetalLayer's colorspace to nil (native/
// unmanaged) after init — on the P3 panel that reads as oversaturated. Idempotent + cheap.
// [R7a item 12] Counted, because "the 2D window is frozen" had no machine-readable signal
// at all: the display link ticked, Qcommon_Frame ran, the mixer was pumped, and the ONLY
// thing that had stopped was this call succeeding. `swapok` advancing after a VR exit is the
// assertion that the picture is moving again — and it is one a simulator can make, which a
// screenshot of an immersive space never is.
static unsigned long long s_swap_ok, s_swap_fail;
void VID_iOS_ANGLE_SwapStats(unsigned long long *ok, unsigned long long *fail)
{
    if (ok) *ok = s_swap_ok;
    if (fail) *fail = s_swap_fail;
}

static void  a_swap_buffers(void) {
#if defined(Q2_XR_UI) && Q2_XR_UI
    // 3D mode: the engine renders offscreen; never present to (or block on) the hidden
    // window surface — vkQuake's hard rule (hidden-drawable acquire can stall forever).
    // (GPU flushing happens in VID_iOS_XR3_EndFrame, in the UIKit-free glue file.)
    if (q2_xr3_mode) return;
#endif
    a_force_srgb();
    if (eglSwapBuffers(s_dpy, s_surf)) s_swap_ok++; else s_swap_fail++;
}
static void  a_swap_interval(int v) { eglSwapInterval(s_dpy, v); }
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

#if defined(Q2_XR_UI) && Q2_XR_UI
// Merged 2D+3D: the stereo machinery lives in immersive/xr3_glue.m (UIKit-free — UIKit's
// transitive OpenGLES import shadows ANGLE's GL prototypes as 'unavailable' on visionOS).
// The glue needs the window's pixel size to restore the render size on 3D exit.
void VID_iOS_XR3_GetWindowSize(int *w, int *h) { *w = s_width; *h = s_height; }

// ---- ANGLE context ownership (the prerequisite for a dedicated engine thread) --------
// The EGL context is made current on the MAIN thread inside Qcommon_Init (a_init) and
// re-bound on main by a_set_mode, and every GL call in this app has so far come from the
// main-thread display link. An EGL context may be current on at most ONE thread, so moving
// frame ownership to an engine thread is not "spawn a thread and call Qcommon_Frame": the
// context must be released by main FIRST and acquired by the new owner SECOND, with no
// window in between where both believe they hold it.
//
// These two calls are the whole handover, and they are deliberately dumb: the ORDERING
// lives in the VR entry/exit sequence (q2_vr_glue.m), in one place, so it can be read.
// A release that races an in-flight frame is a GPU fault with no stack, so the engine
// thread is always stopped and joined-by-poll before main takes the context back.
void VID_iOS_ANGLE_ReleaseContext(void)
{
    if (s_dpy == EGL_NO_DISPLAY) return;
    if (!eglMakeCurrent(s_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT))
        Com_EPrintf("vid_angle: release context failed 0x%x\n", eglGetError());
}

bool VID_iOS_ANGLE_AcquireContext(void)
{
    if (s_dpy == EGL_NO_DISPLAY || s_ctx == EGL_NO_CONTEXT) return false;
    // Surfaceless is correct here: in VR (and in 3D) the engine renders into FBOs wrapping
    // app-owned Metal textures and never presents to the hidden window surface, which
    // a_swap_buffers already refuses to touch. Binding the window surface from a non-main
    // thread is exactly the hidden-drawable acquire that can stall forever.
    EGLSurface surf = q2_xr3_mode ? EGL_NO_SURFACE : s_surf;
    if (!eglMakeCurrent(s_dpy, surf, surf, s_ctx)) {
        Com_EPrintf("vid_angle: acquire context failed 0x%x\n", eglGetError());
        return false;
    }
    return true;
}

// [R7a, Q-VR8 item 12] THE STEP THAT WAS MISSING FROM EVERY VR EXIT.
//
// The exit finalize took the context back on main by calling AcquireContext from INSIDE
// Q2_VR_FinishEngineStop, which runs BEFORE VID_iOS_XR3_SetMode(0) clears q2_xr3_mode. So
// the ternary above chose EGL_NO_SURFACE and main came back SURFACELESS — for the rest of
// the process's life, because nothing else ever re-binds s_surf. The display link resumed,
// Qcommon_Frame ran, the mixer was pumped (music kept playing, which is the tell), and
// every eglSwapBuffers failed against a surface that was not current: the 2D window froze
// on the entry frame. The self-heal that would have caught it, VID_iOS_Resize, early-returns
// while q2_xr3_mode is set and the un-park resize is issued before the dismissal, so by the
// time mode is off the size matches and it bails.
//
// Ordering is the whole fix, so it is a NAMED call rather than a second Acquire whose
// correctness depends on a flag set three lines earlier in a different file. It is called
// from the `off` branch of VID_iOS_XR3_SetMode, before that branch's GL calls, so every path
// that reaches the finalize — ordinary exit, failed-entry rollback, the Digital Crown belt —
// gets it, and it reports the OUTCOME (donors' L-6: a request is not an outcome).
bool VID_iOS_ANGLE_BindWindowSurface(void)
{
    if (s_dpy == EGL_NO_DISPLAY || s_ctx == EGL_NO_CONTEXT) return false;
    if (s_surf == EGL_NO_SURFACE) {
        Com_EPrintf("vid_angle: no window surface to bind\n");
        return false;
    }
    if (!eglMakeCurrent(s_dpy, s_surf, s_surf, s_ctx)) {
        Com_EPrintf("vid_angle: bind window surface failed 0x%x\n", eglGetError());
        return false;
    }
    Q2_VR_ConPrintf("SURFACEBIND window=1 draw=%p\n", (void *)s_surf);   // [R7b 8a] never notify
    return true;
}
#endif // Q2_XR_UI

#endif // Q2_USE_ANGLE
