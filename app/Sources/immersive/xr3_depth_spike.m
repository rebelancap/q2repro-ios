// xr3_depth_spike.m — the R0 go/no-go for VR depth handoff (charter D3, SEAMS §2).
//
// THE QUESTION. In VR the compositor must be given the scene's DEPTH, not just its colour,
// or reprojection treats the whole world as if it lived on one plane. q2repro's depth today
// is a GL RENDERBUFFER (xr3_glue.m) — there is no MTLTexture behind it to hand over. Two
// routes, and the cheap one is unverified:
//
//   ROUTE A  Wrap an app-created DEPTH-format MTLTexture through
//            eglCreateImageKHR(EGL_METAL_TEXTURE_ANGLE) and attach it as the FBO's
//            GL_DEPTH_ATTACHMENT, exactly the way colour is wrapped today. If ANGLE's
//            Metal backend accepts it, the compositor samples engine depth directly and
//            the handoff costs nothing.
//   ROUTE B  Attach a GL depth TEXTURE (no new EGL capability needed), then run one
//            fullscreen GL pass per eye that samples it and writes CONVERTED depth into a
//            shared COLOUR texture — the proven sharing mechanism. Costs one extra
//            fullscreen pass per eye, which is what this spike measures.
//
// Both are exercised here, in the app, against the ANGLE build the app actually links and
// with the ANGLE context the engine actually renders with. A host-side probe would be
// answering a different question about a different build.
//
// Run it with `q2vrdepthspike` on a dev build; results go to the console and the black box.
// Harness and recorded results: spikes/vr-depth/.

#if defined(Q2_XR_UI) && Q2_XR_UI && defined(Q2_DEV_BUILD) && Q2_DEV_BUILD

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#include <stdio.h>
#include <string.h>

#define EGL_EGLEXT_PROTOTYPES
#define GL_GLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>

#include "shared/shared.h"
#include "common/common.h"
#include "system/system.h"   // Sys_Milliseconds

extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a] Com_Printf, never the notify feed

#ifndef EGL_METAL_TEXTURE_ANGLE
#define EGL_METAL_TEXTURE_ANGLE 0x34A7
#endif

extern void Q2_VR_BlackBoxPin(const char *key, const char *line);

static void spike_say(const char *key, const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    Q_vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    Q2_VR_ConPrintf("DEPTHSPIKE %s\n", buf);
    char pinned[512];
    Q_snprintf(pinned, sizeof(pinned), "DEPTHSPIKE %s", buf);
    Q2_VR_BlackBoxPin(key, pinned);
}

// --------------------------------------------------------------------------------------
// Shared GL bits
// --------------------------------------------------------------------------------------

static GLuint compile(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024] = {0};
        glGetShaderInfoLog(s, sizeof(log) - 1, NULL, log);
        Com_EPrintf("DEPTHSPIKE shader: %s\n", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint link_program(const char *vs, const char *fs)
{
    GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glLinkProgram(p);
    glDeleteShader(v); glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { glDeleteProgram(p); return 0; }
    return p;
}

// A fullscreen triangle drawn from gl_VertexID — no VBO, no attribute plumbing, so the
// spike measures the pass and not its own scaffolding.
static const char *VS_FULLSCREEN =
    "#version 300 es\n"
    "out vec2 uv;\n"
    "void main(){\n"
    "  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);\n"
    "  uv = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);\n"
    "}\n";

// Writes a known constant depth, so a readback has an expected value to check against.
static const char *FS_WRITE_DEPTH =
    "#version 300 es\n"
    "precision highp float;\n"
    "in vec2 uv;\n"
    "out vec4 frag;\n"
    "void main(){ gl_FragDepth = 0.25; frag = vec4(uv, 0.0, 1.0); }\n";

// ROUTE B's resolve: sample the engine's forward-Z depth texture and write the
// compositor's reverse-infinite depth through, as a colour. The algebra is SEAMS §2.4:
//   z_units = zfar*znear / (zfar - d*(zfar - znear))       (undo the forward-Z projection)
//   z_m     = z_units / worldScale                          (Quake units -> metres)
//   d_comp  = n_c / z_m                                     (reverse-Z, infinite far)
// R32F would be the natural target; RGBA8 is used here because that is the format the
// existing EGL_METAL_TEXTURE_ANGLE colour path already proves it can share, and this pass
// is being COSTED, not shipped.
static const char *FS_RESOLVE_DEPTH =
    "#version 300 es\n"
    "precision highp float;\n"
    "uniform highp sampler2D uDepth;\n"
    "uniform float uZNear;     // engine units\n"
    "uniform float uZFar;      // engine units (gl_static.world.size * 2, per map)\n"
    "uniform float uScale;     // engine units per metre\n"
    "uniform float uNearC;     // compositor near plane, metres\n"
    "in vec2 uv;\n"
    "out vec4 frag;\n"
    "void main(){\n"
    "  float d = texture(uDepth, uv).r;\n"
    "  float zu = (uZFar * uZNear) / max(uZFar - d * (uZFar - uZNear), 1e-6);\n"
    "  float zm = zu / uScale;\n"
    "  float dc = uNearC / max(zm, 1e-6);\n"
    "  frag = vec4(dc, dc, dc, 1.0);\n"
    "}\n";

// --------------------------------------------------------------------------------------
// ROUTE A — depth-format MTLTexture through EGL_METAL_TEXTURE_ANGLE
// --------------------------------------------------------------------------------------

static bool route_a_try(EGLDisplay dpy, id<MTLDevice> dev, MTLPixelFormat mfmt,
                        const char *name, int w, int h)
{
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:mfmt width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> mtl = [dev newTextureWithDescriptor:td];
    if (!mtl) { spike_say("depthA", "routeA fmt=%s result=NO_MTLTEXTURE", name); return false; }

    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)(__bridge void *)mtl, NULL);
    if (img == EGL_NO_IMAGE_KHR) {
        spike_say("depthA", "routeA fmt=%s result=EGLIMAGE_REFUSED eglerror=0x%x", name, eglGetError());
        return false;
    }
    GLuint tex = 0, fbo = 0, color = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    GLenum glerr = glGetError();

    // A depth attachment alone does not make a complete FBO on ES; give it a colour buddy.
    glGenTextures(1, &color);
    glBindTexture(GL_TEXTURE_2D, color);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, tex, 0);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);

    bool complete = (st == GL_FRAMEBUFFER_COMPLETE);
    bool depthLanded = false;
    if (complete) {
        // Prove depth is actually WRITTEN through the wrap, not merely accepted: clear to
        // 1.0, write 0.25, then draw a second pass at 0.5 with GL_LESS. If the depth
        // attachment is live the second pass is rejected and the colour keeps the first
        // pass's value. This is an occlusion proof, and it needs no readback path.
        glViewport(0, 0, w, h);
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LESS);
        glDepthMask(GL_TRUE);
        glClearDepthf(1.0f);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

        GLuint prog = link_program(VS_FULLSCREEN, FS_WRITE_DEPTH);
        GLuint occl = link_program(VS_FULLSCREEN,
            "#version 300 es\nprecision highp float;\nout vec4 frag;\n"
            "void main(){ gl_FragDepth = 0.5; frag = vec4(1.0, 0.0, 0.0, 1.0); }\n");
        GLuint vao = 0; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
        if (prog && occl) {
            glUseProgram(prog); glDrawArrays(GL_TRIANGLES, 0, 3);
            glUseProgram(occl); glDrawArrays(GL_TRIANGLES, 0, 3);
            uint8_t px[4] = {0};
            glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
            // Red would mean the farther pass was NOT rejected — i.e. depth is inert.
            depthLanded = !(px[0] > 200 && px[1] < 60);
            spike_say("depthA", "routeA fmt=%s occlusion_pixel=(%u,%u,%u) depth_live=%d",
                      name, px[0], px[1], px[2], depthLanded ? 1 : 0);
        }
        glDeleteProgram(prog); glDeleteProgram(occl);
        glDeleteVertexArrays(1, &vao);
        glDisable(GL_DEPTH_TEST);
        glFinish();   // GL's writes must be complete before Metal reads the same texture

        // The claim that matters is not "GL accepted the attachment" but "METAL can read
        // the depth GL wrote". Blit the private depth texture into Shared storage and read
        // the float back: it must be the 0.25 the first pass wrote, not the 1.0 clear.
        // SAMPLE it from Metal — do NOT blit it. A blit or getBytes on a depth texture is
        // not a supported copy on this backend and aborts the process (it did, once, and
        // took the app down mid-spike). Sampling is also the operation the compositor will
        // actually perform, so this is the claim worth proving.
        if (mfmt == MTLPixelFormatDepth32Float) {
            NSError *err = nil;
            id<MTLLibrary> lib = [dev newLibraryWithSource:
                @"#include <metal_stdlib>\n"
                 "using namespace metal;\n"
                 "kernel void probe(texture2d<float, access::read> d [[texture(0)]],\n"
                 "                  device float *out [[buffer(0)]],\n"
                 "                  constant uint2 &at [[buffer(1)]],\n"
                 "                  uint tid [[thread_position_in_grid]]) {\n"
                 "  if (tid == 0) out[0] = d.read(at).r;\n"
                 "}\n" options:nil error:&err];
            id<MTLComputePipelineState> pso =
                lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"probe"] error:&err] : nil;
            id<MTLBuffer> outBuf = [dev newBufferWithLength:sizeof(float)
                                                    options:MTLResourceStorageModeShared];
            if (pso && outBuf) {
                simd_uint2 at = { (uint32_t)(w / 2), (uint32_t)(h / 2) };
                id<MTLCommandQueue> q = [dev newCommandQueue];
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:pso];
                [ce setTexture:mtl atIndex:0];
                [ce setBuffer:outBuf offset:0 atIndex:0];
                [ce setBytes:&at length:sizeof(at) atIndex:1];
                [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
                [ce endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                float sample = *(const float *)outBuf.contents;
                spike_say("depthAm", "routeA fmt=%s metal_sampled_depth=%.4f expected=0.2500 match=%d",
                          name, sample, (sample > 0.24f && sample < 0.26f) ? 1 : 0);
            } else {
                spike_say("depthAm", "routeA fmt=%s metal_sample=PIPELINE_FAILED err=%s",
                          name, err.localizedDescription.UTF8String ?: "(none)");
            }
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &tex);
    glDeleteTextures(1, &color);
    eglDestroyImageKHR(dpy, img);

    spike_say("depthA", "routeA fmt=%s eglimage=OK gl_bind_err=0x%x fbo_status=0x%x complete=%d depth_live=%d",
              name, glerr, st, complete ? 1 : 0, depthLanded ? 1 : 0);
    return complete && depthLanded;
}

// --------------------------------------------------------------------------------------
// ROUTE B — GL depth texture + one fullscreen resolve pass per eye, MEASURED
// --------------------------------------------------------------------------------------

static bool route_b_measure(int w, int h, double *msPerPass, GLenum depthFmt, const char *fmtName)
{
    GLuint depthTex = 0, colorTex = 0, outTex = 0, fboScene = 0, fboOut = 0, vao = 0;
    bool ok = false;

    glGenTextures(1, &depthTex);
    glBindTexture(GL_TEXTURE_2D, depthTex);
    glTexStorage2D(GL_TEXTURE_2D, 1, depthFmt, w, h);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    // NONE, not COMPARE_REF_TO_TEXTURE: the resolve wants the raw depth VALUE, and a
    // comparison sampler would silently return 0/1 instead.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);

    glGenTextures(1, &colorTex);
    glBindTexture(GL_TEXTURE_2D, colorTex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);

    glGenTextures(1, &outTex);
    glBindTexture(GL_TEXTURE_2D, outTex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, w, h);

    glGenFramebuffers(1, &fboScene);
    glBindFramebuffer(GL_FRAMEBUFFER, fboScene);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, colorTex, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, depthTex, 0);
    GLenum stScene = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (stScene != GL_FRAMEBUFFER_COMPLETE) {
        spike_say("depthB", "routeB fmt=%s scene_fbo=0x%x INCOMPLETE", fmtName, stScene);
        goto done;
    }

    glGenFramebuffers(1, &fboOut);
    glBindFramebuffer(GL_FRAMEBUFFER, fboOut);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, outTex, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        spike_say("depthB", "routeB fmt=%s out_fbo INCOMPLETE", fmtName);
        goto done;
    }

    glGenVertexArrays(1, &vao);
    glBindVertexArray(vao);

    // Fill the depth texture once with a known value.
    {
        glBindFramebuffer(GL_FRAMEBUFFER, fboScene);
        glViewport(0, 0, w, h);
        glEnable(GL_DEPTH_TEST); glDepthFunc(GL_ALWAYS); glDepthMask(GL_TRUE);
        glClearDepthf(1.0f); glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        GLuint prog = link_program(VS_FULLSCREEN, FS_WRITE_DEPTH);
        if (!prog) { spike_say("depthB", "routeB fmt=%s write shader FAILED", fmtName); goto done; }
        glUseProgram(prog);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glDeleteProgram(prog);
        glDisable(GL_DEPTH_TEST);
    }

    GLuint resolve = link_program(VS_FULLSCREEN, FS_RESOLVE_DEPTH);
    if (!resolve) { spike_say("depthB", "routeB fmt=%s resolve shader FAILED", fmtName); goto done; }

    glBindFramebuffer(GL_FRAMEBUFFER, fboOut);
    glViewport(0, 0, w, h);
    glDisable(GL_DEPTH_TEST);
    glUseProgram(resolve);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, depthTex);
    glUniform1i(glGetUniformLocation(resolve, "uDepth"), 0);
    glUniform1f(glGetUniformLocation(resolve, "uZNear"), 2.0f);      // gl_znear default
    glUniform1f(glGetUniformLocation(resolve, "uZFar"),  8192.0f);   // world.size * 2, mid map
    glUniform1f(glGetUniformLocation(resolve, "uScale"), 34.0f);     // charter worldScale
    glUniform1f(glGetUniformLocation(resolve, "uNearC"), 0.1f);      // compositor near plane

    // Correctness before cost: the converted value must be finite, non-zero, and match the
    // algebra for the depth we wrote. d=0.25 -> z_units ~ 2.667 -> z_m ~ 0.0784 -> dc ~ 1.27,
    // which saturates an RGBA8 target at 1.0. A ZERO here would be indistinguishable from
    // "nothing rendered", which is precisely the sky/reprojection hazard, so assert it.
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glFinish();
    {
        uint8_t px[4] = {0};
        glReadPixels(w / 2, h / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        spike_say("depthB", "routeB fmt=%s converted_pixel=(%u,%u,%u) nonzero=%d",
                  fmtName, px[0], px[1], px[2], px[0] > 0 ? 1 : 0);
        if (px[0] == 0) {
            spike_say("depthB", "routeB fmt=%s CONVERSION READ ZERO — depth texture not sampled", fmtName);
            glDeleteProgram(resolve);
            goto done;
        }
    }

    // Cost. glFinish either side and average over N passes: ANGLE has no timer queries on
    // this backend, and one pass is below the noise floor of a wall clock.
    {
        const int N = 200;
        glFinish();
        double t0 = Sys_Milliseconds();
        for (int i = 0; i < N; i++) glDrawArrays(GL_TRIANGLES, 0, 3);
        glFinish();
        double t1 = Sys_Milliseconds();
        *msPerPass = (t1 - t0) / N;
        spike_say("depthB", "routeB fmt=%s size=%dx%d passes=%d total=%.0fms per_eye=%.3fms",
                  fmtName, w, h, N, t1 - t0, *msPerPass);
    }
    glDeleteProgram(resolve);
    ok = true;

done:
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (fboScene) glDeleteFramebuffers(1, &fboScene);
    if (fboOut)   glDeleteFramebuffers(1, &fboOut);
    if (vao)      glDeleteVertexArrays(1, &vao);
    glDeleteTextures(1, &depthTex);
    glDeleteTextures(1, &colorTex);
    glDeleteTextures(1, &outTex);
    return ok;
}

// --------------------------------------------------------------------------------------

void Q2_VR_DepthSpike(int w, int h)
{
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) { Com_EPrintf("DEPTHSPIKE no current EGL display\n"); return; }
    if (w <= 0 || h <= 0) { w = 2976; h = 1680; }   // the shipped 60%-quality eye target

    spike_say("depth0", "begin eye=%dx%d gl_vendor=%s gl_version=%s", w, h,
              (const char *)glGetString(GL_VENDOR), (const char *)glGetString(GL_VERSION));

    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    bool aOK = false;
    aOK |= route_a_try(dpy, dev, MTLPixelFormatDepth32Float,          "Depth32Float", w, h);
    aOK |= route_a_try(dpy, dev, MTLPixelFormatDepth32Float_Stencil8, "Depth32Float_Stencil8", w, h);
    aOK |= route_a_try(dpy, dev, MTLPixelFormatDepth16Unorm,          "Depth16Unorm", w, h);

    double msD24 = 0, msD32 = 0;
    bool b24 = route_b_measure(w, h, &msD24, GL_DEPTH_COMPONENT24,  "GL_DEPTH_COMPONENT24");
    bool b32 = route_b_measure(w, h, &msD32, GL_DEPTH_COMPONENT32F, "GL_DEPTH_COMPONENT32F");

    spike_say("depthV", "VERDICT routeA_wrap=%s routeB_resolve=%s d24=%.3fms d32=%.3fms per_eye "
                        "(x2 eyes = %.3fms per host frame at %dx%d)",
              aOK ? "WORKS" : "REFUSED",
              (b24 || b32) ? "WORKS" : "FAILED",
              msD24, msD32, 2.0 * (b32 ? msD32 : msD24), w, h);
}

#endif // Q2_XR_UI && Q2_DEV_BUILD
