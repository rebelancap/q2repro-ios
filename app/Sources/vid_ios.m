// vid_ios.m — native EAGL OpenGL ES 3.0 video driver (vid_driver_t) for q2repro.
// Implements the 24-slot platform video interface (inc/client/video.h) against a
// CAEAGLLayer the app hands us. The engine renders through qgl* pointers resolved
// via get_proc_addr; we own context + framebuffer + present. (D3/D4.)
#if !(defined(Q2_USE_ANGLE) && Q2_USE_ANGLE)   // EAGL driver; vid_angle.m is the ANGLE variant
#import <UIKit/UIKit.h>
#import <QuartzCore/CAEAGLLayer.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES3/gl.h>
#import <OpenGLES/ES3/glext.h>
#import <dlfcn.h>
#include <stdio.h>

#include "shared/shared.h"
#include "common/common.h"
#include "common/cvar.h"
#include "common/zone.h"
#include "client/video.h"
#include "refresh/refresh.h"
#include "common/cmd.h"

// --- shared state with the app shell (main.m) --------------------------------
static CAEAGLLayer *s_layer;          // the drawable, set before Qcommon_Init
static EAGLContext *s_ctx;
static GLuint s_fbo, s_colorRB, s_depthRB;
static GLint  s_width, s_height;      // drawable pixels
static int    s_scale = 1;

// Engine console output → stderr AND Documents/qconsole.log (devicectl doesn't
// reliably capture stderr from a device app; the file is pullable via `devicectl copy from`).
void Sys_ConsoleOutput(const char *text, size_t len) {
    fwrite(text, 1, len, stderr); fflush(stderr);
    static FILE *lf; static int tried;
    if (!lf && !tried) {
        tried = 1;
        NSString *p = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                       stringByAppendingPathComponent:@"qconsole.log"];
        lf = fopen(p.fileSystemRepresentation, "w");
    }
    if (lf) { fwrite(text, 1, len, lf); fflush(lf); }
}

// Called by the app shell before Qcommon_Init.
void VID_iOS_SetLayer(void *layer) { s_layer = (__bridge CAEAGLLayer *)layer; }

// --- input glue (M5): look accumulator + console command bridge ---------------
static float s_look_dx, s_look_dy;
void VID_iOS_AddLook(float dx, float dy) { s_look_dx += dx; s_look_dy += dy; }
void VID_iOS_Command(const char *cmd) { Cmd_ExecuteString(&cmd_buffer, cmd); }
// The drawable pixel size (for the app / diagnostics).
void VID_iOS_GetDrawable(int *w, int *h) { if (w) *w = s_width; if (h) *h = s_height; }

// --- framebuffer (re)creation bound to the layer -----------------------------
static void destroy_framebuffer(void)
{
    if (s_fbo)     { glDeleteFramebuffers(1, &s_fbo);      s_fbo = 0; }
    if (s_colorRB) { glDeleteRenderbuffers(1, &s_colorRB); s_colorRB = 0; }
    if (s_depthRB) { glDeleteRenderbuffers(1, &s_depthRB); s_depthRB = 0; }
}

static bool create_framebuffer(void)
{
    destroy_framebuffer();

    glGenFramebuffers(1, &s_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);

    glGenRenderbuffers(1, &s_colorRB);
    glBindRenderbuffer(GL_RENDERBUFFER, s_colorRB);
    if (![s_ctx renderbufferStorage:GL_RENDERBUFFER fromDrawable:s_layer]) {
        Com_EPrintf("vid_ios: renderbufferStorage:fromDrawable: failed\n");
        return false;
    }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, s_colorRB);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH,  &s_width);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &s_height);

    glGenRenderbuffers(1, &s_depthRB);
    glBindRenderbuffer(GL_RENDERBUFFER, s_depthRB);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, s_width, s_height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, s_depthRB);

    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (st != GL_FRAMEBUFFER_COMPLETE) {
        Com_EPrintf("vid_ios: framebuffer incomplete (0x%x)\n", st);
        return false;
    }
    // Tell the renderer this is the "screen" framebuffer (EAGL has no usable FBO 0).
    R_SetDefaultFramebuffer(s_fbo);
    return true;
}

// --- vid_driver_t callbacks --------------------------------------------------
static bool ios_probe(void) { return true; }

static bool ios_init(void)
{
    if (!s_layer) { Com_EPrintf("vid_ios: no layer set before init\n"); return false; }
    s_layer.opaque = YES;
    s_layer.drawableProperties = @{ kEAGLDrawablePropertyRetainedBacking : @NO,
                                    kEAGLDrawablePropertyColorFormat : kEAGLColorFormatRGBA8 };
    s_ctx = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES3];
    if (!s_ctx || ![EAGLContext setCurrentContext:s_ctx]) {
        Com_EPrintf("vid_ios: failed to create ES3 context\n");
        return false;
    }
    s_scale = (int)lrintf((float)s_layer.contentsScale);
    if (s_scale < 1) s_scale = 1;
    Com_Printf("vid_ios: EAGL ES3 context created (scale %d)\n", s_scale);
    return true;   // framebuffer built in set_mode (after QGL_Init)
}

static void ios_shutdown(void)
{
    if (s_ctx) {
        [EAGLContext setCurrentContext:s_ctx];
        destroy_framebuffer();
        [EAGLContext setCurrentContext:nil];
        s_ctx = nil;
    }
}

static void ios_set_mode(void)
{
    [EAGLContext setCurrentContext:s_ctx];
    if (create_framebuffer())
        R_ModeChanged(s_width, s_height, 0);
    SCR_ModeChanged();
}

static char *ios_get_mode_list(void)
{
    // Single fixed mode = the drawable size (or a placeholder pre-framebuffer).
    int w = s_width  ? s_width  : (int)(s_layer.bounds.size.width  * s_layer.contentsScale);
    int h = s_height ? s_height : (int)(s_layer.bounds.size.height * s_layer.contentsScale);
    char buf[64];
    Q_snprintf(buf, sizeof(buf), "%dx%d", w ? w : 1280, h ? h : 720);
    return Z_CopyString(buf);
}

static int   ios_get_dpi_scale(void) { return s_scale; }
static void  ios_update_gamma(const byte *table) { (void)table; }  // texture-baked on iOS

static void *ios_get_proc_addr(const char *sym) { return dlsym(RTLD_DEFAULT, sym); }

// On-device framebuffer capture (reads the freshly-rendered frame BEFORE present,
// so the pixels are valid regardless of retained-backing). Writes a PPM. Reusable
// for M4 parity captures. Set by VID_iOS_RequestCapture(path).
static volatile int s_capture;
static char s_cap_path[1024];
void VID_iOS_RequestCapture(const char *path) { Q_strlcpy(s_cap_path, path, sizeof(s_cap_path)); s_capture = 1; }

static void ios_capture_now(void)
{
    int w = s_width, h = s_height;
    if (w <= 0 || h <= 0) return;
    unsigned char *px = malloc((size_t)w * h * 4);
    if (!px) return;
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    FILE *f = fopen(s_cap_path, "wb");
    NSLog(@"[vid_ios] capture: %dx%d fbo=%u fopen=%p path=%s", w, h, s_fbo, (void*)f, s_cap_path);
    if (f) {
        fprintf(f, "P6\n%d %d\n255\n", w, h);
        for (int y = h - 1; y >= 0; y--)            // GL is bottom-up; flip
            for (int x = 0; x < w; x++) {
                unsigned char *p = px + ((size_t)y * w + x) * 4;
                fputc(p[0], f); fputc(p[1], f); fputc(p[2], f);
            }
        fclose(f);
        Com_Printf("vid_ios: wrote capture %s (%dx%d)\n", s_cap_path, w, h);
    }
    free(px);
}

static void  ios_swap_buffers(void)
{
    static int sw = 0;
    if (sw++ == 0) NSLog(@"[vid_ios] first present (swap_buffers reached, fbo=%u %dx%d)", s_fbo, s_width, s_height);
    if (s_capture) { s_capture = 0; ios_capture_now(); }
    glBindRenderbuffer(GL_RENDERBUFFER, s_colorRB);
    [s_ctx presentRenderbuffer:GL_RENDERBUFFER];
    // keep our fbo bound as the render target for the next frame
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
}

static void  ios_swap_interval(int val) { (void)val; }  // display-link driven

static char *ios_get_selection_data(void) { return NULL; }
static char *ios_get_clipboard_data(void) { return NULL; }
static void  ios_set_clipboard_data(const char *data) { (void)data; }

static bool  ios_init_mouse(void) { return true; }    // must be true or IN_Init early-returns
                                                       // before registering in_grab (touch is M5)
static void  ios_shutdown_mouse(void) {}
static void  ios_grab_mouse(bool grab) { (void)grab; }
static void  ios_warp_mouse(int x, int y) { (void)x; (void)y; }
static bool  ios_get_mouse_motion(int *dx, int *dy) {
    *dx = (int)lrintf(s_look_dx); *dy = (int)lrintf(s_look_dy);
    s_look_dx -= *dx; s_look_dy -= *dy;   // keep sub-pixel remainder
    return (*dx || *dy);
}

static void  ios_pump_events(void) {}   // UIKit delivers events; nothing to pump here

const vid_driver_t vid_ios = {
    .name = "ios",
    .probe = ios_probe,
    .init = ios_init,
    .shutdown = ios_shutdown,
    .fatal_shutdown = ios_shutdown,
    .pump_events = ios_pump_events,
    .get_mode_list = ios_get_mode_list,
    .get_dpi_scale = ios_get_dpi_scale,
    .set_mode = ios_set_mode,
    .update_gamma = ios_update_gamma,
    .get_proc_addr = ios_get_proc_addr,
    .swap_buffers = ios_swap_buffers,
    .swap_interval = ios_swap_interval,
    .get_selection_data = ios_get_selection_data,
    .get_clipboard_data = ios_get_clipboard_data,
    .set_clipboard_data = ios_set_clipboard_data,
    .init_mouse = ios_init_mouse,
    .shutdown_mouse = ios_shutdown_mouse,
    .grab_mouse = ios_grab_mouse,
    .warp_mouse = ios_warp_mouse,
    .get_mouse_motion = ios_get_mouse_motion,
};
#endif // !Q2_USE_ANGLE
