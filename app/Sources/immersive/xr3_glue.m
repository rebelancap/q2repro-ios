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
#include <time.h>

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
#include "q2_vr_glue.h"

extern void Q2_VR_ConPrintf(const char *fmt, ...) q_printf(1, 2);   // [R7b 8a] Com_Printf, never the notify feed
// [R19] Declared by hand for the same reason as everything else here: XR3Bridging.h drags
// UIKit in, and the GL prototype trap at the top of this file is what that costs. These three
// are the memory breadcrumbs from q2_vr_dumps.m — the resize log below is the ONE line that
// can tell the next device run whether a Render Quality step is a jetsam, because a jetsam
// kill writes nothing of its own and the black box survives it.
extern void Q2_VR_MemStats(float *cur_mb, float *peak_mb, float *avail_mb);
extern int  Q2_VR_MemLine(char *out, int size);
extern void Q2_VR_BlackBoxPin(const char *key, const char *line);
extern void Q2_VR_BlackBoxLog(const char *line);

#ifndef EGL_METAL_TEXTURE_ANGLE
#define EGL_METAL_TEXTURE_ANGLE 0x34A7
#endif
#ifndef EGL_SYNC_METAL_SHARED_EVENT_ANGLE
#define EGL_SYNC_METAL_SHARED_EVENT_ANGLE 0x34D8
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_LO_ANGLE 0x34DA
#define EGL_SYNC_METAL_SHARED_EVENT_SIGNAL_VALUE_HI_ANGLE 0x34DB
#endif

// Declared in inc/client/client.h, which this file deliberately does not include (it drags
// the whole client in). Without the prototype clang treats the call as an implicit
// declaration — caught by scripts/vr-syntax-check.sh.
extern void SCR_ModeChanged(void);
extern void SCR_HudScaleChanged(float mul);            // overlay 0026/0029 (HUD scale only)
extern float Q2_VR_HudSize(void);                      // [R7b item 8] the HUD Size row

extern void V_SetStereoOffset(float offset);           // overlay 0016
extern void V_SetStereoConvergence(float c);           // overlay 0020
extern void VID_iOS_XR3_GetWindowSize(int *w, int *h); // vid_angle.m
extern bool VID_iOS_ANGLE_BindWindowSurface(void);     // vid_angle.m (R7a item 12)
// src/refresh/gl.h is the renderer's INTERNAL header and dragging it in here would collide
// with ANGLE's GL prototypes, so the one symbol this file needs from it is declared by hand.
// It is the engine's own 2D batch flush, and the redirect below is not correct without it.
extern void GL_Flush2D(void);
// Same reason, and the one the HUD sub-rect does not work without: GL_Setup2D is what turns
// `r_config` into an actual glViewport + ortho. The engine calls it at R_BeginFrame and again
// on the way out of the world render — both BEFORE the 2D-redirect bracket — so a switch made
// inside the bracket changes the LAYOUT the 2D code computes without changing the projection
// it is rasterised through, and the HUD lands in the wrong place at the wrong scale. (The
// panel shape gets away with switching without this because it switches between frames, at
// the arbitration transition, where R_BeginFrame picks the new size up on its own.)
extern void GL_Setup2D(void);

int q2_xr3_mode;   // read by vid_angle.m's swap gate

// Eye buffer ring: [eye][buf], XR3_EYE_BUFS deep. The engine renders both eyes into
// buf s_ping each tick; on GPU completion the pair is published (s_pub) and s_ping
// advances. RGBA8 (engine GL output is 8-bit anyway; 16F doubled every byte of
// bandwidth for nothing) and NOT mipmapped — the compositor mip-chains its own
// private copy (SoH parity).
//
// [R9] FIVE buffers, and the "full ring turn of margin" the 3-deep comment used to claim is
// now provided by the READER GATE below rather than asserted. Three was never a turn of
// margin under the in-flight gate: BeginEye(0) blocks while two frames are on the GPU and is
// released the instant the NEXT pair publishes, so the engine begins overwriting a slot at
// exactly the end of the acquired pair's lifetime — while the compositor is still sampling
// it. Two more slots make the collision rare; s_slotReaders makes it impossible.
#define XR3_EYE_BUFS 5

// [R19] THE RING DEPTH IS A MEMORY LEVER, so it is a variable with a compile-time MAXIMUM
// rather than a constant. Five slots at 2.0x VR Render Quality is 3840x3648 per eye:
// 10 colour + 10 depth + 5 UI eye-sized surfaces at 4 bytes a pixel is 1.4 GB of Metal
// textures before the engine's own working set, and a jetsam kill leaves NO crash report --
// which is exactly the shape of the reported "crash while increasing the render quality" on
// 1.0.11.22 (and of the 1.0.11.17 map-load death that put Q2_VR_MemStats here in the first
// place). The budget in Q2_VR_ReportPhysicalSize spends this FIRST -- a shallower ring is
// invisible to the player, a smaller eye target is not -- and only clamps the extent when
// even a 3-deep ring will not fit.
//
// s_ringWanted is written by the budget (any thread); s_ringActive is LATCHED by
// xr3_make_textures on the engine thread and is the only value the ring arithmetic reads,
// so the depth can never change under a frame that is already indexing with it.
static atomic_int s_ringWanted = XR3_EYE_BUFS;
static atomic_int s_ringActive = XR3_EYE_BUFS;   // [R19 review] read cross-thread by the budget

void VID_iOS_XR3_SetRingDepth(int n)
{
    if (n < 2) n = 2;
    if (n > XR3_EYE_BUFS) n = XR3_EYE_BUFS;
    atomic_store(&s_ringWanted, n);
}
int VID_iOS_XR3_RingDepth(void) { return s_ringActive; }

static struct {
    void *mtl;               // retained MTLTexture (via CFBridgingRetain)
    EGLImageKHR img;
    GLuint glTex, fbo;
    int w, h;
    bool wrapped;
    // VR only: a per-eye, per-slot DEPTH texture, wrapped the same way colour is. The 3D
    // panel writes its own synthetic far depth and needs none of this; VR does, because the
    // compositor reprojects against depth and without real per-eye depth the world smears
    // on every head turn.
    void *depthMtl;
    EGLImageKHR depthImg;
    GLuint depthTex;
} s_buf[2][XR3_EYE_BUFS];

// The 2D-redirect UI surface (charter D6). ONE per ring slot, so it is published in the same
// atomic step as the colour pair it belongs to — a HUD sampled from a different frame than
// the world behind it is a mismatch that reads as a tracking bug, which is how that class of
// defect survives a round. Same SIZE as an eye, deliberately: `scr.hud_scale` is derived from
// `r_config.width/height`, which in this mode is the eye texture, so a UI target of any other
// size would need its own R_ModeChanged accounting and would lay the HUD out for a screen
// that does not exist. Colour only — the engine's 2D pass has depth testing off, and the
// quad's depth is written by the composite fragment at a distance the compositor can
// reproject against.
static struct {
    void *mtl;
    EGLImageKHR img;
    GLuint glTex, fbo;
    int w, h;
    bool wrapped;
} s_ui[XR3_EYE_BUFS];
static _Atomic(void *) s_pubUI;
static GLuint s_currentEyeFbo;            // what UIEnd binds back to (engine thread)
static bool   s_uiCleared;                // cleared once per host frame, not once per bracket

static int s_ping;                        // engine thread only
static _Atomic(void *) s_pub[2];          // last GPU-completed pair (compositor reads)
static _Atomic(void *) s_pubDepth[2];     // the SAME frame's depth pair
static atomic_int s_framesRendered;       // PUBLISHED stereo frames since entering 3D
static atomic_int s_inFlight;             // submitted-but-not-GPU-complete engine frames
static MTLSharedEventListener *s_listener;

// ---- ownership of PUBLISHED textures (D-VR-R3.1) ---------------------------------------
// Every s_pub / s_pubDepth / s_pubUI slot holds its OWN +1 on the texture it names,
// independent of the ring's retain in s_buf / s_ui. Before R3 the completion block captured
// RAW pointers borrowed from the ring, and a live Render Quality change (which replaces the
// whole ring mid-play) could CFRelease a texture a scheduled block was about to publish —
// a use-after-free that reached the compositor as garbage or a crash. The sequencing drain
// below closes the same hole from the other side; this is the belt to its braces, and it is
// what keeps a stale publish harmless rather than fatal if the drain ever times out.
//
// A superseded publish is RETIRED, not released inline: the compositor samples the published
// pointers with takeUnretainedValue, so there is a hair-thin window between its atomic load
// and ARC's retain. Holding the old object for half a second after it stops being published
// makes that window unreachable. Only published textures are retired (at most two colour,
// two depth, one UI); the ring's own refs still drop immediately, so a resize does not carry
// two full generations of eye targets.
static void xr3_retire(void *tex)
{
    if (!tex) return;
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("q2.xr3.retire", DISPATCH_QUEUE_SERIAL); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)), q, ^{
        CFRelease(tex);
    });
}

static void *xr3_hold(void *tex) { return tex ? (void *)CFRetain(tex) : NULL; }

// Defined with the drain it belongs to, further down; declared here because the ring
// replacement (xr3_make_textures) sits above that point and is one of its callers.
static int xr3_invalidate_publishes(void);

// [R7a item 2] THE PUBLISH SEQUENCE COUNTER.
//
// The five slots below are five sequential atomic stores, and the compositor reads them as
// four separate accessor calls. A publish landing between two of those calls pairs frame N's
// COLOUR with frame N+1's DEPTH — which is one of the shapes a compositor reprojection error
// takes, and it looks like a tracking bug rather than a pairing bug, so it survives rounds.
// The comment on the publish block said "the SAME atomic step", and that was true of the
// writer's intent and false of the reader's view.
//
// A seqlock closes it by construction. The writer bumps this ODD before the stores and EVEN
// after; a reader that sees an odd value, or a different value across the read, retries. No
// lock is taken on either side, which matters because the writer is a GPU completion block
// and the reader is the compositor thread inside its frame.
static atomic_uint s_pubSeq;

// [R8] THE POSE THE PIXELS WERE RENDERED WITH, travelling WITH the pixels.
// `Q2_VR_WaitRendered` closes on the CPU — the engine finished SUBMITTING frame N — but the
// eye textures for N are only published one to two frames later, from the GPU-completion
// block below. So the compositor was setting `drawable.deviceAnchor` to the anchor of frame
// N while presenting the pixels of N-1 or N-2: the compositor then reprojects older imagery
// against a newer head pose, which is zero error when still and proportional to angular
// velocity when turning — the reported "image shifting in place as I look left and right".
// The donors' rule (quake3e `Q3EVR.m` ~1999-2050): the question is not "was the rendezvous
// fresh" but "did the imagery this frame will PRESENT get taken this frame?" — so the pose
// id rides the published set through the same seqlock as the five textures, and the shell
// submits the anchor that pair was actually rendered with.
static _Atomic uint64_t s_framePoseId;    // set by the engine thread before EndFrame
static _Atomic uint64_t s_pubPoseId;      // the id of the pair currently published

// [R9 item 1] THE RING SLOT THE PUBLISHED PAIR LIVES IN, and how many consumers are still
// reading it.
//
// The in-flight gate bounds the producer at 2 frames, but it releases BeginEye the moment the
// NEXT pair publishes — i.e. the engine starts overwriting a slot exactly at the end of the
// acquired pair's life, while the compositor is still SAMPLING that pair's depth textures
// straight out of the ring (there is no cross-queue ordering between ANGLE's Metal queue and
// the compositor's). A torn depth read displaces new-frame-depth pixels differently from
// old-frame-depth pixels, which is a doubled edge for a flash while the head turns and
// nothing at all while it is still. Eye 0 is written first each frame, so its window opens
// sooner and is wider — the left eye is worse, exactly as reported.
//
// The fix is the donors' one (quake3e `q3e_vr_ensure_copy`, vkQuake `VKQVR.m`): the consumer
// copies what it needs into its OWN private textures and samples only the copies. This
// counter is the other half — it makes the copy's own read safe by holding the slot for the
// life of the consumer's command buffer, and it is what proves the collision was real.
static _Atomic unsigned s_slotReaders[XR3_EYE_BUFS];
static _Atomic int s_pubSlot;             // ring slot of the published pair (-1 = none)
static atomic_uint s_pubSerial;           // monotonic publish serial, written INSIDE the seqlock
static atomic_int s_slotFrames;           // BeginEye(0) calls since entering stereo
static atomic_int s_slotWaits;            // ... of which found a reader still on their slot
static atomic_int s_slotHeals;            // ... of which gave up waiting (must stay 0)

// ---- [R14] THE PUBLISH FENCE, and the constants that must ride the pair ----------------
//
// Reported on 1.0.11.16: "a duplicate of the world flickers next to the original in a flash",
// worst in the RIGHT eye right after a level loads and settling over minutes. Eye 1 is the
// LAST thing drawn before the publish sync, so it has the least GPU time between its final
// draw and the signal; every first-use cost (Metal PSO compiles, texture uploads, lightmap
// rebuild) widens that gap and every one of them retires within the first minutes. The
// mechanism that predicts all of it at once is a publish that lands before eye 1's GPU work
// has retired, so the compositor samples the slot's PREVIOUS occupant — five host frames
// older, a visibly different head pose — blended with the half-written new frame.
//
// Two things close it, and they are independent:
//
//  1. THE GPU-SIDE WAIT (mode 3, the default). The compositor's Metal queue has no ordering
//     with ANGLE's whatsoever; today the only thing between them is the CPU listener that
//     arms the publish. Mode 3 publishes the shared event and value ANGLE signals for this
//     pair, and the presenting command buffer encodes a waitForEvent on them before it blits
//     or samples anything — the dependency is STATED to the GPU rather than inferred from a
//     CPU notification. It CANNOT deadlock: a pair is only ever published from inside the
//     listener block, which fires when the event has already reached that value, so the wait
//     the compositor encodes is on a value that is already signalled by construction. Epoch
//     invalidation and teardown clear the slot to NULL (xr3_invalidate_publishes), and a NULL
//     event means "no wait" — the mode-0 behaviour — not a stall.
//  2. THE PRE-SYNC BARRIER (modes 1 and 2). If ANGLE encodes its signal into a command buffer
//     that does not already carry eye 1's work, no wait on that value can help, because the
//     value is reached too early on both sides. Mode 1 (eglWaitUntilWorkScheduledANGLE) and
//     mode 2 (glFinish) close that from the producer's end; mode 2 is the heavy hammer and
//     the A/B, never the ship. `fence_us` is what they cost, so the warm-up curve the
//     diagnosis predicts is measurable rather than argued about.
static atomic_int s_pubFenceMode = 3;
static _Atomic(void *) s_pubFenceEvent;      // MTLSharedEvent (+1) of the PUBLISHED pair
static _Atomic uint64_t s_pubFenceValue;     // ... and the value it is signalled at
static atomic_int s_fenceSamples;
static _Atomic uint64_t s_fenceUsTotal;
static _Atomic uint64_t s_fenceUsMax;

// The depth-decode constants of the PUBLISHED pair. Written inside the seqlock beside the
// textures and read inside the same seq check, so a map load cannot change `zfar` under a
// pair that was rendered before it.
static q2_vr_depthconst_t s_pubDepthConst;

extern const void *Q2_VR_AcquiredPose(void);   // q2_vr_glue.m: the pose this frame rendered with

static uint64_t xr3_now_us(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1000ull; }

void VID_iOS_XR3_SetPubFence(int mode)
{
    if (mode < 0 || mode > 3) mode = 3;
    atomic_store(&s_pubFenceMode, mode);
    // Reset the window with the mode: a mean that averages two modes together is a number
    // nobody can act on, and this is the console A/B's whole point.
    atomic_store(&s_fenceSamples, 0);
    atomic_store(&s_fenceUsTotal, 0);
    atomic_store(&s_fenceUsMax, 0);
}
int VID_iOS_XR3_PubFence(void) { return atomic_load(&s_pubFenceMode); }
void VID_iOS_XR3_PubFenceStats(double *meanUs, double *maxUs)
{
    int n = atomic_exchange(&s_fenceSamples, 0);
    uint64_t tot = atomic_exchange(&s_fenceUsTotal, 0);
    uint64_t mx = atomic_exchange(&s_fenceUsMax, 0);
    if (meanUs) *meanUs = n > 0 ? (double)tot / (double)n : 0.0;
    if (maxUs)  *maxUs  = (double)mx;
}

static void xr3_zero_slot_readers(void)
{
    for (int b = 0; b < XR3_EYE_BUFS; b++) atomic_store(&s_slotReaders[b], 0u);
}

// Consumer side. Bounds-checked and clamped at zero on release: every path that tears the
// ring down zeroes these, and a release arriving after that must not wrap the counter to
// 4 billion and wedge the producer forever.
void VID_iOS_XR3_SlotRetain(int slot)
{
    if (slot < 0 || slot >= XR3_EYE_BUFS) return;
    atomic_fetch_add(&s_slotReaders[slot], 1u);
}
void VID_iOS_XR3_SlotRelease(int slot)
{
    if (slot < 0 || slot >= XR3_EYE_BUFS) return;
    unsigned c = atomic_load(&s_slotReaders[slot]);
    while (c > 0 && !atomic_compare_exchange_weak(&s_slotReaders[slot], &c, c - 1u)) { }
}
void VID_iOS_XR3_SlotStats(int *frames, int *waits, int *heals)
{
    if (frames) *frames = atomic_load(&s_slotFrames);
    if (waits)  *waits  = atomic_load(&s_slotWaits);
    if (heals)  *heals  = atomic_load(&s_slotHeals);
}

// `retained` says whether the caller already owns a ref it is handing over (the completion
// block does; every clear site does not). Either way the slot ends up owning exactly one.
static void xr3_pub_set(_Atomic(void *) *slot, void *tex, bool retained)
{
    void *newv = retained ? tex : xr3_hold(tex);
    void *old = atomic_exchange(slot, newv);
    if (!old) return;
    if (old == newv) CFRelease(old);   // re-published the same texture: drop the duplicate
    else             xr3_retire(old);
}

// One shared depth-stencil renderbuffer: the engine renders eyes/buffers sequentially,
// so all four FBOs can share it. (Real z-buffer required — without it the scene
// z-fights: holes, the viewmodel drawing through itself.)
static GLuint s_depthRb;
static int s_depthW, s_depthH;
// VR: the depth attachment becomes a texture, so stencil needs its own renderbuffer.
// gl_shadows sets gl_static.stencil_buffer_bit and the scene clear then names it, so
// dropping stencil silently would either break shadows or clear a buffer that is not
// attached. One shared stencil buffer is fine for the same reason the depth one was: the
// engine renders eyes and ring slots sequentially.
static GLuint s_stencilRb;
static int s_stencilW, s_stencilH;
static bool s_vrDepth;                    // VR depth handoff armed (engine thread)
static int  s_vrForcedW, s_vrForcedH;     // VR eye size from the physical colour texture

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

static GLuint xr3_shared_stencil(int w, int h) {
    if (s_stencilRb && s_stencilW == w && s_stencilH == h) return s_stencilRb;
    if (s_stencilRb) glDeleteRenderbuffers(1, &s_stencilRb);
    glGenRenderbuffers(1, &s_stencilRb); glBindRenderbuffer(GL_RENDERBUFFER, s_stencilRb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_STENCIL_INDEX8, w, h);
    s_stencilW = w; s_stencilH = h;
    return s_stencilRb;
}

// Depth handoff, route A (DECISIONS D-VR-R0a): ANGLE's Metal backend accepts a
// Depth32Float MTLTexture through EGL_METAL_TEXTURE_ANGLE as a GL_DEPTH_ATTACHMENT, GL
// writes it, and Metal samples back the exact value. That was proved with three escalating
// checks in R0 — framebuffer completeness, then that depth is LIVE (an occlusion test),
// then that Metal reads what GL wrote — because "the FBO was complete" is not the claim
// that matters. Depth16Unorm is refused by the backend; Depth32Float_Stencil8 also works
// and is the fallback shape if the separate stencil buffer ever proves awkward.
//
// TRAP, paid for in the spike: never blit or getBytes a depth texture to verify it. That
// path aborts on this backend. Sample it from a shader or a compute kernel — which is what
// the composite does every frame anyway.
static void xr3_free_depth(int eye, int buf, EGLDisplay dpy) {
    if (s_buf[eye][buf].depthImg) { eglDestroyImageKHR(dpy, s_buf[eye][buf].depthImg); s_buf[eye][buf].depthImg = NULL; }
    if (s_buf[eye][buf].depthTex) { glDeleteTextures(1, &s_buf[eye][buf].depthTex); s_buf[eye][buf].depthTex = 0; }
    if (s_buf[eye][buf].depthMtl) { CFRelease(s_buf[eye][buf].depthMtl); s_buf[eye][buf].depthMtl = NULL; }
}

static bool xr3_make_depth(int eye, int buf, EGLDisplay dpy, int w, int h) {
    xr3_free_depth(eye, buf, dpy);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                           width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) { Com_EPrintf("xr3: no depth MTLTexture %dx%d\n", w, h); return false; }
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)(__bridge void *)t, NULL);
    if (img == EGL_NO_IMAGE_KHR) {
        Com_EPrintf("xr3: no depth EGLImage 0x%x\n", eglGetError());
        return false;
    }
    GLuint gt = 0;
    glGenTextures(1, &gt); glBindTexture(GL_TEXTURE_2D, gt);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    s_buf[eye][buf].depthMtl = (void *)CFBridgingRetain(t);
    s_buf[eye][buf].depthImg = img;
    s_buf[eye][buf].depthTex = gt;
    return true;
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
        xr3_free_depth(eye, buf, dpy);
    }
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)s_buf[eye][buf].mtl, NULL);
    if (img == EGL_NO_IMAGE_KHR) { Com_EPrintf("xr3: no EGLImage 0x%x\n", eglGetError()); return 0; }
    GLuint glTex = 0, fbo = 0;
    glGenTextures(1, &glTex); glBindTexture(GL_TEXTURE_2D, glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTex, 0);
    if (s_vrDepth && xr3_make_depth(eye, buf, dpy, s_buf[eye][buf].w, s_buf[eye][buf].h)) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
                               s_buf[eye][buf].depthTex, 0);
        // Stencil is attached only if the backend accepts it beside a depth TEXTURE. It
        // does not on ANGLE-Metal (measured: the combination reports incomplete every
        // time), so VR runs without a stencil buffer and stencil ops become no-ops. The
        // only consumer is gl_shadows, which VR entry turns off for exactly this reason;
        // the alternative — Depth32Float_Stencil8, which the R0 spike also proved — costs
        // a wider depth texture for a feature VR does not use. One line, said once.
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                                  xr3_shared_stencil(s_buf[eye][buf].w, s_buf[eye][buf].h));
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            static bool said;
            if (!said) { said = true;
                Q2_VR_ConPrintf("xr3: VR depth texture accepted, separate stencil refused - "
                           "running without stencil (gl_shadows is off in VR)\n"); }
            glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER, 0);
        }
    } else {
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                                  xr3_shared_depth(s_buf[eye][buf].w, s_buf[eye][buf].h));
    }
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE) { Com_EPrintf("xr3: eye FBO incomplete 0x%x\n", st); return 0; }
    s_buf[eye][buf].img = img; s_buf[eye][buf].glTex = glTex; s_buf[eye][buf].fbo = fbo;
    s_buf[eye][buf].wrapped = true;
    return fbo;
}

// ---- [R20] MSAA EYE RENDERING ----------------------------------------------------------
//
// WHY THIS EXISTS. Until R20 the only anti-aliasing VR had was brute force: render each eye
// at up to 1.75x the drawable per axis — three times its pixels, 24 MP a frame against a
// 2048x1984 physical per-eye texture — and let the compositor resample it down, with CAS
// (VRShell) buying back the softness that costs. On 1.0.11.23 that lands the engine at 51 Hz
// against a 60 Hz layer with 13-29 late frames per ~55. MSAA attacks the SAME artefact
// (geometry edges) where it is produced, at a fraction of the shading cost: 4x MSAA shades
// once per pixel and only rasterises and depth-tests four times, so a 1.0x-1.25x eye target
// with 4x MSAA carries roughly a third of the fragment work of 1.75x supersampling while
// resolving edges at least as well. What MSAA does NOT fix is aliasing INSIDE a triangle
// (texture and shader aliasing), which supersampling does — so this is a row the player
// trades against Render Quality, not a silent replacement for it. The intended fidelity/perf
// point for the headset is VR Render Quality 1.0x-1.25x with 4x MSAA; the A/B against
// 1.75x + CAS is written up in artifacts/vr-r20-msaa/PLAN-and-verify.md.
//
// SHAPE. ONE SHARED multisampled FBO (colour + depth renderbuffers), not one per eye and not
// one per ring slot — for exactly the reason the shared depth renderbuffer above gives: the
// engine renders eyes and ring slots SEQUENTIALLY on one context, so the MS buffer only ever
// has to hold one eye at a time, and it is resolved before the next eye touches it. That
// makes MSAA a fixed two surfaces instead of 2 x ring x 2: 130 MB at 4x/2048x1984 rather
// than 1.3 GB. The ring, the publish, the seqlock, the slot readers and the resize path are
// untouched — the MS buffer is scratch that never leaves this file.
//
// RESOLVE. glBlitFramebuffer from the MS FBO into the wrapped eye FBO at the END of the eye
// (the next BeginEye, or EndFrame for the last one). Colour and depth are resolved in TWO
// separate blits, both GL_NEAREST — a multisample-resolve blit may not filter, and depth may
// never filter — separate so a GL error names WHICH one the backend refused. Depth matters
// because the compositor reprojects against the eye's Depth32Float texture (route A): a
// colour-only resolve would publish this frame's colour beside the previous frame's depth,
// which is the exact shape of a reprojection defect that reads as a tracking bug.
//
// WHY NOT GL_EXT_multisampled_render_to_texture (implicit resolve, tile memory only, no
// resolve bandwidth at all)? The ANGLE we ship DOES export it — evidence, since ANGLE's
// source is pruned after the build: the strings `GL_EXT_multisampled_render_to_texture`,
// `GL_EXT_multisampled_render_to_texture2` and `glFramebufferTexture2DMultisampleEXT` are all
// present in spikes/angle-prebuilt-visionos/libGLESv2.framework/libGLESv2, alongside the
// Metal-backend feature flags `allowMultisampleStoreAndResolve` and
// `enableMultisampledRenderToTextureOnNonTilers`. But that extension resolves COLOUR only;
// the follow-on ..._texture2 permits a depth/stencil texture attachment and explicitly leaves
// its resolved contents UNDEFINED. VR needs resolved depth every frame, so the implicit path
// cannot carry this render on its own, and correctness beats the bandwidth. The capability is
// probed and logged anyway (`implicit=yes/no`) so a later round can A/B it if a depth-less
// pass ever appears.
//
// EVERY failure here is loud and falls back to no MSAA: an incomplete MS FBO, a refused
// multisample storage, or a refused resolve blit disables MSAA for the session with a console
// line naming the GL error, and the eye path continues exactly as it did in R19.
static int    s_msWanted;                 // samples asked for this frame (0/2/4)
static int    s_msMax = -1;               // GL_MAX_SAMPLES, -1 = not probed yet
static bool   s_msImplicit;               // GL_EXT_multisampled_render_to_texture present
static bool   s_msFailed;                 // a GL failure disabled MSAA for this session
static GLuint s_msFbo, s_msColorRb, s_msDepthRb;
static int    s_msW, s_msH, s_msSamples;  // what the MS renderbuffers currently hold
static GLuint s_msPendingDst;             // eye FBO awaiting a resolve (0 = none)
static int    s_msPendingW, s_msPendingH;
static bool   s_msPendingDepth;           // ... and whether its depth is a texture (route A)
// [R22] What the BACKEND allocated, as opposed to what was asked for. GLES lets
// glRenderbufferStorageMultisample round the sample count UP, and ANGLE-Metal turns a "2x"
// request into a 4-sample renderbuffer (Metal reports no 2-sample support). The memory
// planner budgets from this once it is known, so the "2x Anti-aliasing" row stops being
// costed at half what it actually allocates. Written on the engine thread, read on the
// compositor thread, hence the atomic; 0 = nothing allocated yet.
static _Atomic int s_msBackendSamples;

int VID_iOS_XR3_MsaaActive(void)  { return s_msFbo ? s_msSamples : 0; }
int VID_iOS_XR3_MsaaBackendSamples(void) { return atomic_load(&s_msBackendSamples); }
int VID_iOS_XR3_MsaaMax(void)     { return s_msMax > 0 ? s_msMax : 0; }
int VID_iOS_XR3_MsaaImplicit(void){ return s_msImplicit ? 1 : 0; }

static void xr3_ms_probe(void)
{
    if (s_msMax >= 0) return;
    GLint mx = 0;
    glGetIntegerv(GL_MAX_SAMPLES, &mx);
    while (glGetError() != GL_NO_ERROR) { }     // a refused query is "no MSAA", not a wedge
    s_msMax = (int)mx;
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    s_msImplicit = ext && strstr(ext, "GL_EXT_multisampled_render_to_texture") != NULL;
    Q2_VR_ConPrintf("xr3: MSAA caps max_samples=%d implicit_rtt=%s (resolve path: explicit "
                    "glBlitFramebuffer, colour + depth)\n",
                    s_msMax, s_msImplicit ? "yes" : "no");
}

static void xr3_ms_free(void)
{
    if (s_msFbo)     { glDeleteFramebuffers(1, &s_msFbo);       s_msFbo = 0; }
    if (s_msColorRb) { glDeleteRenderbuffers(1, &s_msColorRb);  s_msColorRb = 0; }
    if (s_msDepthRb) { glDeleteRenderbuffers(1, &s_msDepthRb);  s_msDepthRb = 0; }
    s_msW = s_msH = s_msSamples = 0;
    atomic_store(&s_msBackendSamples, 0);
    s_msPendingDst = 0;                 // the destination may be going away with it
}

// Engine thread, context current. Returns true when s_msFbo is a complete MS FBO of exactly
// (w, h, samples) whose depth format MATCHES the eye FBO's depth attachment — the resolve
// blit requires identical formats, and VR's depth attachment is a Depth32Float texture.
static bool xr3_ms_ensure(int w, int h, int samples)
{
    if (s_msFbo && s_msW == w && s_msH == h && s_msSamples == samples) return true;
    xr3_ms_free();
    while (glGetError() != GL_NO_ERROR) { }
    const GLenum depthFmt = s_vrDepth ? GL_DEPTH_COMPONENT32F : GL_DEPTH24_STENCIL8;
    const GLenum depthAtt = s_vrDepth ? GL_DEPTH_ATTACHMENT   : GL_DEPTH_STENCIL_ATTACHMENT;
    glGenRenderbuffers(1, &s_msColorRb);
    glBindRenderbuffer(GL_RENDERBUFFER, s_msColorRb);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, GL_RGBA8, w, h);
    glGenRenderbuffers(1, &s_msDepthRb);
    glBindRenderbuffer(GL_RENDERBUFFER, s_msDepthRb);
    glRenderbufferStorageMultisample(GL_RENDERBUFFER, samples, depthFmt, w, h);
    glGenFramebuffers(1, &s_msFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_msFbo);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, s_msColorRb);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, depthAtt, GL_RENDERBUFFER, s_msDepthRb);
    GLenum st  = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    GLenum err = glGetError();
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE || err != GL_NO_ERROR) {
        Q2_VR_ConPrintf("xr3: MSAA %dx at %dx%d REFUSED (fbo 0x%x, gl 0x%x) - "
                        "rendering without MSAA\n", samples, w, h, st, err);
        xr3_ms_free();
        s_msFailed = true;
        return false;
    }
    s_msW = w; s_msH = h; s_msSamples = samples;
    // [R20 verify] REPORT WHAT THE BACKEND ACTUALLY ALLOCATED, not what was asked for. GLES
    // 3.0 lets glRenderbufferStorageMultisample round the sample count UP ("the resulting
    // value for RENDERBUFFER_SAMPLES is guaranteed to be greater than or equal to samples"),
    // and ANGLE-Metal does exactly that here: on the visionOS 27 simulator the "2x" row
    // produces a renderbuffer that is pixel-for-pixel identical to the 4x one, because Metal
    // reports no 2-sample support and ANGLE picks 4. Without this line the console says "2x"
    // about a 4x surface and the settings row looks like a cheaper option that does not exist.
    GLint realC = samples, realD = samples;
    glBindRenderbuffer(GL_RENDERBUFFER, s_msColorRb);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_SAMPLES, &realC);
    glBindRenderbuffer(GL_RENDERBUFFER, s_msDepthRb);
    glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_SAMPLES, &realD);
    glBindRenderbuffer(GL_RENDERBUFFER, 0);
    while (glGetError() != GL_NO_ERROR) { }     // a refused query costs the log line, nothing else
    // [R22] The MB figure is derived from the BACKEND's count too, and so is the number the
    // memory planner budgets with (Q2_VR_NoteMsaaBackendSamples' reader): a 2x request that
    // ANGLE rounds to 4 costs 4x the bytes, and printing the requested count next to a
    // requested-count MB total made both halves of that under-report agree with each other.
    const int realMax = (int)(realC > realD ? realC : realD);
    atomic_store(&s_msBackendSamples, realMax >= samples ? realMax : samples);
    Q2_VR_ConPrintf("xr3: MSAA %dx armed at %dx%d (%.0f MB shared: colour RGBA8 + depth %s; "
                    "backend samples colour=%d depth=%d)\n",
                    samples, w, h,
                    (double)w * h * (double)VID_iOS_XR3_MsaaBackendSamples() * 8.0 / (1024.0 * 1024.0),
                    s_vrDepth ? "32F" : "24S8", (int)realC, (int)realD);
    return true;
}

// Resolve the eye that was just rendered, if any. Called at the TOP of BeginEye (for the
// previous eye) and at the top of EndFrame (for the last one), i.e. after every draw that
// eye will ever receive and before anything reads the wrapped texture.
static void xr3_ms_resolve(void)
{
    if (!s_msPendingDst || !s_msFbo) { s_msPendingDst = 0; return; }
    const GLuint dst = s_msPendingDst;
    const int w = s_msPendingW, h = s_msPendingH;
    s_msPendingDst = 0;
    while (glGetError() != GL_NO_ERROR) { }
    // Blits obey the scissor; masks are stated rather than assumed, because the engine's last
    // 2D pass leaves whatever it left and a masked resolve is a black eye nobody can explain.
    GLboolean cmask[4] = { GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE };
    GLboolean dmask = GL_TRUE;
    glGetBooleanv(GL_COLOR_WRITEMASK, cmask);
    glGetBooleanv(GL_DEPTH_WRITEMASK, &dmask);
    // [R20 review] the scissor enable is restored too: the engine sets it once per pass and
    // expects it to persist, and this runs before every eye.
    GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST);
    glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glDepthMask(GL_TRUE);
    glBindFramebuffer(GL_READ_FRAMEBUFFER, s_msFbo);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, dst);
    glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    GLenum ec = glGetError();
    GLenum ed = GL_NO_ERROR;
    if (s_msPendingDepth) {
        // GLES 3.0 permits a multisample->single-sample DEPTH resolve through a NEAREST blit
        // with matching formats. ANGLE's Metal backend carries the machinery for it
        // (MTLStoreActionMultisampleResolve, the `allowMultisampleStoreAndResolve` feature),
        // but the ANGLE source is pruned after the build, so THIS is unverified until a run
        // says otherwise — hence the error check and the loud fallback rather than a claim.
        glBlitFramebuffer(0, 0, w, h, 0, 0, w, h, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
        ed = glGetError();
    }
    glColorMask(cmask[0], cmask[1], cmask[2], cmask[3]);
    glDepthMask(dmask);
    if (scissor) glEnable(GL_SCISSOR_TEST);
    if (ec != GL_NO_ERROR || ed != GL_NO_ERROR) {
        Q2_VR_ConPrintf("xr3: MSAA resolve REFUSED (colour 0x%x, depth 0x%x) - "
                        "disabling MSAA for this session\n", ec, ed);
        s_msFailed = true;
        s_currentEyeFbo = dst;          // the engine's default framebuffer is the eye again
        R_SetDefaultFramebuffer(dst);
        xr3_ms_free();
        glBindFramebuffer(GL_FRAMEBUFFER, dst);
        return;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, dst);
}

// How many samples the player asked for, clamped by what this context can actually do.
// VR only: the 3D panel's depth is synthetic and its target is not reprojected, so MSAA
// there would be cost with no owner. Read through Q2_VR_MsaaWanted, which caches on the
// settings generation the sheet and `q2vrset vr_msaa` both bump.
static int xr3_ms_samples(void)
{
    if (s_msFailed || !s_vrDepth) return 0;
    xr3_ms_probe();
    if (s_msMax < 2) return 0;
    int want = Q2_VR_MsaaWanted();
    if (want > s_msMax) want = s_msMax;
    if (want < 2) return 0;
    return want;
}

// ---- the 2D-redirect UI surface --------------------------------------------------------
// Engine thread only, and armed only in VR: the shipped 3D panel has nowhere to put a
// separate UI layer (it IS a screen), so redirecting there would delete its HUD.
static bool s_uiArmed;

void VID_iOS_XR3_SetUIRedirect(int on)
{
    if (s_uiArmed == (on != 0)) return;
    s_uiArmed = on != 0;
    if (!s_uiArmed) xr3_pub_set(&s_pubUI, NULL, false);
    Q2_VR_ConPrintf("xr3: 2D redirect %s\n", s_uiArmed ? "ON (HUD/menus/console to the UI texture)" : "off");
}

static GLuint xr3_wrap_ui(int buf)
{
    if (s_ui[buf].wrapped) return s_ui[buf].fbo;
    if (!s_ui[buf].mtl) return 0;
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return 0;
    if (s_ui[buf].img) {
        eglDestroyImageKHR(dpy, s_ui[buf].img);
        glDeleteTextures(1, &s_ui[buf].glTex);
        glDeleteFramebuffers(1, &s_ui[buf].fbo);
        s_ui[buf].img = NULL;
    }
    EGLImageKHR img = eglCreateImageKHR(dpy, EGL_NO_CONTEXT, EGL_METAL_TEXTURE_ANGLE,
                                        (EGLClientBuffer)s_ui[buf].mtl, NULL);
    if (img == EGL_NO_IMAGE_KHR) { Com_EPrintf("xr3: no UI EGLImage 0x%x\n", eglGetError()); return 0; }
    GLuint glTex = 0, fbo = 0;
    glGenTextures(1, &glTex); glBindTexture(GL_TEXTURE_2D, glTex);
    glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, (GLeglImageOES)img);
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, glTex, 0);
    GLenum st = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    if (st != GL_FRAMEBUFFER_COMPLETE) { Com_EPrintf("xr3: UI FBO incomplete 0x%x\n", st); return 0; }
    s_ui[buf].img = img; s_ui[buf].glTex = glTex; s_ui[buf].fbo = fbo;
    s_ui[buf].wrapped = true;
    return fbo;
}

// The panel shape's state, defined below with the rest of it — the HUD bracket has to
// know whether r_config is ALREADY switched, and the bracket is written earlier in the file.
#define XR3_PANEL_ASPECT (16.0f / 9.0f)
static int s_panelShape;

// ---- the HUD shape (R5, Q-VR9) ----------------------------------------------------------
// "Health and ammo sit at the corners of a square." The panel got its widescreen layout in
// R3 by composing into a 16:9 sub-rect of the eye texture; the head-locked HUD did not,
// because a WORLD frame's `r_config` must stay the eye size for the projection the
// compositor reprojects against — so a widescreen HUD means changing r_config twice per
// rendered frame, and at 90 Hz the fear was SCR_ModeChanged's console reflow and menu
// rebuild.
//
// The way out is that neither of those is needed here. A VR frame with a menu or the console
// up is not a world frame at all — arbitration routes it to the panel — so the only 2D inside
// this bracket is the HUD, the crosshair, centerprint and notify. Their layout depends on
// r_config and `scr.hud_scale`, and overlay 0026 adds SCR_HudScaleChanged, which re-derives
// exactly that and nothing else. The switch is then R_ModeChanged's three assignments plus
// one R_ClampScale, twice a frame — measured in MEASUREMENTS.md, not assumed.
//
// KNOWN AND ACCEPTED: notify lines still wrap at the console's linewidth, which was derived
// at the eye width, so a long notify line wraps a little early. Re-deriving it is
// Con_CheckResize — the one call this design exists to avoid — and the cost of being right
// about it is far higher than the cost of being slightly wrong.
static int s_hudW, s_hudH;      // the sub-rect the HUD composes into, 0x0 when off
static int s_hudActive;         // r_config is currently switched to it (inside the bracket)
static int s_hudWide = 1;       // `q2vrhudwide 0` puts the square layout back, live

void VID_iOS_XR3_SetHudWide(int on) { s_hudWide = on != 0; if (!s_hudWide) { s_hudW = s_hudH = 0; } }
int  VID_iOS_XR3_HudWide(void)      { return s_hudWide; }

// The rect the HUD was last composed into (0x0 = it fills the whole UI texture). The
// compositor asks rather than assumes, exactly as it does for the panel: one number decides
// both the quad's shape and its texture coordinates, and a second source of truth for it is
// how a surface ends up stretched.
void VID_iOS_XR3_UIRect(int *w, int *h)
{
    if (w) *w = s_hudW;
    if (h) *h = s_hudH;
}

int VID_iOS_XR3_UIReady(void) { return s_uiArmed && s_ui[0].mtl != NULL; }
void *VID_iOS_XR3_UITexture(void) { return atomic_load(&s_pubUI); }
void VID_iOS_XR3_UISize(int *w, int *h)
{
    if (w) *w = s_ui[0].mtl ? s_ui[0].w : 0;
    if (h) *h = s_ui[0].mtl ? s_ui[0].h : 0;
}

// The engine calls these through q2vr.ui_begin / ui_end (function pointers, so no
// configuration without a shell needs a stub to link). The bracket appears TWICE per host
// frame — once around SCR_Draw2D inside SCR_DrawActive, once around the menu/console/loading
// half — because V_RenderView sits between them and the world must land in the eye target.
// Hence the clear is owned by the FRAME (reset in BeginEye), not by the bracket.
void VID_iOS_XR3_UIBegin(void)
{
    GLuint fbo = xr3_wrap_ui(s_ping);
    if (!fbo) return;
    // Flush whatever 2D is still batched for the EYE target before the target changes: the
    // engine's 2D is immediate-mode into `tess` and flushed on state changes and at
    // R_EndFrame, so an unflushed batch would be rasterised into whichever framebuffer
    // happens to be bound when it finally goes out.
    GL_Flush2D();
    R_SetDefaultFramebuffer(fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    // Q-VR9: lay the HUD out for a widescreen sub-rect. Only on a WORLD frame — when the
    // panel shape is on, r_config is ALREADY the 16:9 sub-rect for the whole frame and a
    // second switch here would be both wrong and a second source of truth for the same
    // number. Guarded on the eye size being known, because the fit is computed FROM it.
    if (s_hudWide && !s_panelShape && !s_hudActive && s_ui[s_ping].w > 0) {
        int ew = s_ui[s_ping].w, eh = s_ui[s_ping].h;
        int pw = ew, ph = (int)lroundf(ew / XR3_PANEL_ASPECT);
        if (ph > eh) { ph = eh; pw = (int)lroundf(eh * XR3_PANEL_ASPECT); }
        s_hudW = pw & ~1; s_hudH = ph & ~1;
        s_hudActive = 1;
        R_ModeChanged(s_hudW, s_hudH, 0);
        // [R7b item 8] The HUD Size row multiplies the scale the engine would have chosen for
        // this sub-rect. Read here rather than cached: the row applies live, and a slider the
        // player is dragging should resize under their hands.
        SCR_HudScaleChanged(Q2_VR_HudSize());
        GL_Setup2D();          // the projection must follow r_config, or only the layout moves
    }
    if (!s_uiCleared) {
        s_uiCleared = true;
        // Transparent black: the quad is composited with blending, so every pixel the HUD did
        // not draw must contribute nothing at all rather than a black rectangle hanging in
        // front of the world.
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);
    }
}

void VID_iOS_XR3_UIEnd(void)
{
    GL_Flush2D();
    // Restore the EYE shape before anything else can draw: the world projection and the
    // eye viewport both come off r_config, and a world drawn at the HUD's shape is a
    // stereo mismatch the compositor will happily reproject. Paired with the switch in
    // UIBegin and gated on the same flag, so an unbalanced bracket cannot strand it.
    if (s_hudActive) {
        s_hudActive = 0;
        R_ModeChanged(s_buf[0][0].w, s_buf[0][0].h, 0);   // the EYE size, from the eye ring
        // 1.0, NOT the row: leaving the bracket restores the EYE shape, and the HUD Size
        // belongs to the sub-rect the HUD composes into. Carrying it out of the bracket would
        // resize the world's own 2D siblings (the loading plaque, the console) by the HUD's
        // number, which is a different surface answering a control it does not own.
        SCR_HudScaleChanged(1.0f);
        GL_Setup2D();
    }
    R_SetDefaultFramebuffer(s_currentEyeFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_currentEyeFbo);
}

// [R11] THE 2D PASS WITH NO EYE BEHIND IT (`vr_ui_eye 2`). The bracket above is designed to
// be entered from inside an eye's render and to hand that eye's framebuffer back; this makes
// the UI surface the target on BOTH sides of it, so nothing re-opens an eye's Metal pass
// after the eye finished drawing. Called between the eye-1 render and EndFrame, on the engine
// thread, with s_ping still this frame's slot — the same UI texture the bracket would have
// used, published by the same EndFrame.
void VID_iOS_XR3_BeginUIPass(void)
{
    if (!q2_xr3_mode) return;
    GLuint fbo = xr3_wrap_ui(s_ping);
    if (!fbo) return;
    s_currentEyeFbo = fbo;               // UIEnd rebinds this: the same target, not an eye
    R_SetDefaultFramebuffer(fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
}

int VID_iOS_XR3_Active(void) { return q2_xr3_mode; }

// ---- the VR panel shape (R3) -----------------------------------------------------------
// "The 2D panel in VR is a square" — the first headset round. A Vision Pro view is nearly
// square, the VR eye targets are sized from it, and the engine composes its ENTIRE 2D stream
// (menus, console, the demo's own view) for `r_config`. So r_config at the eye size made the
// menus square: nothing was stretched, the layout itself was square.
//
// A world frame must keep the eye shape — the projection has to match the drawable the
// compositor reprojects against — so the shape is switched only for the NON-WORLD frames
// arbitration already routes to the panel. The eye textures are NOT re-created: the engine
// renders into a 16:9 sub-rect anchored at the framebuffer's origin (GL's origin is bottom
// left, and GL_Setup2D's viewport is (0, 0, r_config.width, r_config.height)), and the
// compositor samples exactly that sub-rect onto a 16:9 quad. R_ModeChanged is three
// assignments and SCR_ModeChanged re-derives the HUD scale, so the cost of opening a menu is
// those, not six Metal allocations.
static int s_panelW, s_panelH;            // the sub-rect, 0x0 when the shape is off

void VID_iOS_XR3_PanelRect(int *w, int *h)
{
    if (w) *w = s_panelShape ? s_panelW : 0;
    if (h) *h = s_panelShape ? s_panelH : 0;
}

void VID_iOS_XR3_SetPanelShape(int on)
{
    if (!q2_xr3_mode || !s_buf[0][0].mtl) return;
    on = on != 0;
    if (s_panelShape == on) return;
    s_panelShape = on;
    int ew = s_buf[0][0].w, eh = s_buf[0][0].h;
    if (on) {
        // Fit the widest 16:9 rect inside the eye texture. Both branches are real: a texture
        // wider than 16:9 is height-limited, and the nearly-square VR one is width-limited.
        int pw = ew, ph = (int)lroundf(ew / XR3_PANEL_ASPECT);
        if (ph > eh) { ph = eh; pw = (int)lroundf(eh * XR3_PANEL_ASPECT); }
        s_panelW = pw & ~1; s_panelH = ph & ~1;
        R_ModeChanged(s_panelW, s_panelH, 0);
    } else {
        s_panelW = s_panelH = 0;
        R_ModeChanged(ew, eh, 0);
    }
    SCR_ModeChanged();
    Q2_VR_ConPrintf("xr3: VR 2D shape %s (%dx%d inside a %dx%d eye target)\n",
               on ? "PANEL 16:9" : "eye", on ? s_panelW : ew, on ? s_panelH : eh, ew, eh);
}

// The glue OWNS the eye textures and creates them on demand — BEFORE the immersive space
// opens (Q2_XR3_EngineEnter3D → SetMode runs first). Creating them in the panel renderer
// was the black-first-entry bug: on the first entry SetMode found no textures and failed,
// the engine kept rendering to the window, and the panel sampled never-written memory.
static void xr3_target_size(int *w, int *h);
static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace);
static void xr3_ensure_textures(void) {
    // [R19] s_ringActive, not XR3_EYE_BUFS: with a shrunken ring the slots above it are
    // deliberately empty, and testing them here would re-create the whole ring every frame.
    for (int e = 0; e < 2; e++) for (int b = 0; b < s_ringActive; b++)
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
    // VR sizes from the drawable's PHYSICAL colour texture times the VR render scale, which
    // the compositor reports through Q2_VR_ReportPhysicalSize. The panel budget below is a
    // 16:9 SCREEN formula and is wrong for a nearly-square eye target in every respect.
    if (s_vrForcedW > 0 && s_vrForcedH > 0) { *w = s_vrForcedW; *h = s_vrForcedH; return; }
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

// [R19] EAGERLY DROP THE OLD GENERATION'S GL/EGL/depth objects.
//
// Until R19 a ring replacement set `wrapped = false` and nothing else: the old EGLImage, GL
// texture, FBO and — the expensive one — the per-slot Depth32Float MTLTexture were freed
// LAZILY, inside xr3_wrap, the next time the engine happened to render into that slot. So
// for up to a full ring turn after a Render Quality step the process held the OLD depth ring
// (10 eye-sized surfaces: 429 MB at 1.75x, 560 MB at 2.0x) ON TOP of the whole new ring it
// had just allocated. That transient is a third of the footprint at the exact instant the
// footprint is highest, on a path the player reaches by dragging a slider — and a jetsam
// kill there writes no crash report, which is what "a crash while increasing the render
// quality" with nothing in systemCrashLogs looks like.
//
// Safe to do here, and only here: the caller has drained (no completion block is pending),
// every PUBLISHED texture already owns its own +1 through xr3_pub_set/xr3_retire, and the
// compositor's ARC reference to whatever it acquired keeps that object alive independently
// of the ring's ref. Deleting a GL name never frees the MTLTexture behind it — ANGLE holds
// its own reference through the EGLImage — so the CFRelease below is dropping the RING's
// ref, not the last one. Engine thread, ANGLE context current; if the context is gone we
// leave the old lazy path to it rather than issuing GL calls into no display.
static void xr3_free_generation_gl(void)
{
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return;
    for (int e = 0; e < 2; e++) for (int b = 0; b < XR3_EYE_BUFS; b++) {
        if (s_buf[e][b].img) {
            eglDestroyImageKHR(dpy, s_buf[e][b].img);
            glDeleteTextures(1, &s_buf[e][b].glTex);
            glDeleteFramebuffers(1, &s_buf[e][b].fbo);
            s_buf[e][b].img = NULL; s_buf[e][b].glTex = 0; s_buf[e][b].fbo = 0;
        }
        xr3_free_depth(e, b, dpy);
        s_buf[e][b].wrapped = false;
    }
    for (int b = 0; b < XR3_EYE_BUFS; b++) {
        if (s_ui[b].img) {
            eglDestroyImageKHR(dpy, s_ui[b].img);
            glDeleteTextures(1, &s_ui[b].glTex);
            glDeleteFramebuffers(1, &s_ui[b].fbo);
            s_ui[b].img = NULL; s_ui[b].glTex = 0; s_ui[b].fbo = 0;
        }
        s_ui[b].wrapped = false;
    }
    // [R20] The MSAA buffers are sized to the generation that is going away, and the pending
    // resolve names an FBO that no longer exists. Both go with it; the next BeginEye rebuilds
    // them at the new size.
    xr3_ms_free();
    // The eye FBO the engine last bound belongs to the generation just destroyed. Nothing
    // may hand it back (VID_iOS_XR3_UIEnd does exactly that), so it is cleared with them.
    s_currentEyeFbo = 0;
}

// [R19] Drop a slot's Metal textures outright — used for the slots above the active ring
// depth when the budget shrinks the ring. GL side is already gone (free_generation_gl).
static void xr3_drop_slot(int b)
{
    for (int e = 0; e < 2; e++) if (s_buf[e][b].mtl) {
        CFRelease(s_buf[e][b].mtl);
        s_buf[e][b].mtl = NULL; s_buf[e][b].w = s_buf[e][b].h = 0; s_buf[e][b].wrapped = false;
    }
    if (s_ui[b].mtl) {
        CFRelease(s_ui[b].mtl);
        s_ui[b].mtl = NULL; s_ui[b].w = s_ui[b].h = 0; s_ui[b].wrapped = false;
    }
}

static void xr3_make_textures(id<MTLDevice> dev, int w, int h, bool replace) {
    // [R19] INVALIDATE FIRST, ALLOCATE SECOND. This block used to run at the END of the
    // function, which meant the whole new ring was allocated while the old generation's
    // published set was still named by s_pub/s_pubDepth/s_pubUI — i.e. at the peak of the
    // transient. Nothing about the ordering was load-bearing (the caller has already
    // drained; the epoch bump only has to precede the next scheduled block, and no frame can
    // be scheduled from this thread while it is in here), so it moves ahead of the
    // allocations and takes the retire window with it.
    //
    // Every block scheduled against the OLD ring is stamped with the old epoch and refuses.
    // Nothing published at the new size yet — the consumer draws dim-only until a
    // completed frame lands (it retains whatever it fetched for the in-flight frame).
    // Clearing to NULL under the drain is also what makes a torn read impossible ACROSS a
    // resize: the compositor's readiness test needs BOTH eyes non-NULL, so the only pair it
    // can ever assemble comes from one generation, at one size. (Within a generation a torn
    // read is at most a one-frame eye-time skew between two same-size live textures.)
    xr3_invalidate_publishes();
    xr3_pub_set(&s_pubUI, NULL, false);
    xr3_pub_set(&s_pub[0], NULL, false);
    xr3_pub_set(&s_pub[1], NULL, false);
    xr3_pub_set(&s_pubDepth[0], NULL, false);
    xr3_pub_set(&s_pubDepth[1], NULL, false);
    atomic_store(&s_framesRendered, 0);
    atomic_store(&s_pubPoseId, 0);   // [R8] no pair published: no pose id to match against
    if (replace) xr3_free_generation_gl();

    // [R19] Latch the ring depth the budget asked for. Only a REPLACE may change it: growing
    // or shrinking the ring re-indexes s_ping, and the fill path (replace == false) runs
    // while frames are in flight.
    int ring = s_ringActive;
    if (replace) {
        ring = atomic_load(&s_ringWanted);
        if (ring < 2) ring = 2;
        if (ring > XR3_EYE_BUFS) ring = XR3_EYE_BUFS;
    }

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:w height:h mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    for (int e = 0; e < 2; e++) for (int b = 0; b < ring; b++) if (replace || !s_buf[e][b].mtl) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (t) VID_iOS_XR3_SetEyeTexture2(e, b, (__bridge void *)t);
    }
    // The UI surface rides the same ring at the same size, rebuilt whenever the eyes are.
    for (int b = 0; b < ring; b++) if (replace || !s_ui[b].mtl) {
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        if (!t) continue;
        if (s_ui[b].mtl) CFRelease(s_ui[b].mtl);
        s_ui[b].mtl = (void *)CFRetain((__bridge void *)t);
        s_ui[b].w = w; s_ui[b].h = h;
        s_ui[b].wrapped = false;
    }
    // [R19] Slots above the new depth are not "spare", they are 3 x 56 MB each at 2.0x —
    // the entire point of shrinking the ring. Freed AFTER the new ones exist only because
    // the allocation above can fail; the old ones at the old size are what a failed
    // allocation falls back on, and they are still whole until this line.
    for (int b = ring; b < XR3_EYE_BUFS; b++) xr3_drop_slot(b);
    s_ringActive = ring;
    if (s_ping >= ring) s_ping = 0;
    s_eyeGeneration++;
}

int VID_iOS_XR3_EyeGeneration(void) { return s_eyeGeneration; }

// ---- the resize drain (D-VR-R3.1) ------------------------------------------------------
// s_inFlight is incremented in EndFrame BEFORE the completion block is scheduled and
// decremented INSIDE it after the publish, so it already covers the block's whole lifetime:
// zero means no block is pending and no publish can land. That is exactly the invariant a
// ring replacement needs, and nothing was ever waiting on it — only BeginEye throttled
// against it. Engine thread only, bounded, and it NEVER wedges: on timeout the caller leaves
// the textures alone and tries again on the next frame, because a hitch on a quality change
// is acceptable and a dangling pointer is not.
static bool s_resizePending;              // engine thread: a resize deferred by a busy drain

static bool xr3_drain_publishes(const char *why)
{
    int spins = 0;
    while (atomic_load(&s_inFlight) > 0 && ++spins < 400) usleep(500);   // ≤200 ms
    if (atomic_load(&s_inFlight) > 0) {
        Com_EPrintf("xr3: %s drain timed out (%d in flight) - late publishes will be refused\n",
                    why, atomic_load(&s_inFlight));
        return false;
    }
    return true;
}

// ---- the publish EPOCH (D-VR-R4) -------------------------------------------------------
// The drain above is the fast path, and it is allowed to fail. R3.1 wired its result into the
// resize (which defers and retries next frame) and DISCARDED it at the two other call sites —
// VID_iOS_XR3_SetVRDepth and VID_iOS_XR3_SetMode — which therefore proceeded on a real 200 ms
// timeout with a completion block still outstanding. R3.1's independent retains mean that is
// not a use-after-free, but the sequencing those sites claim was not actually enforced: a late
// block could publish a pair belonging to a torn-down generation, and its late decrement was
// caught only by the compare-exchange clamp.
//
// WHY THOSE TWO SITES CANNOT SIMPLY DEFER, AND THIS DOES NOT REPEAT THE RESIZE'S ANSWER. Both
// are reached from Q2_XR3_EngineEnterVR / Q2_XR3_EngineExitVR (main.m). The exit finalize is
// documented idempotent and UNCONDITIONAL — it runs from the ordinary exit, from the Digital
// Crown belt, and from the rollback of a failed entry — and by the time it calls these it has
// already run Q2_VR_FinishEngineStop, so the engine thread is gone and there is no next frame
// to retry on. A deferral there is a deferral to never. The resize can defer because it is a
// mid-play operation with frames guaranteed to follow; these are teardown, and teardown has to
// finish.
//
// So instead of making the proceed conditional, this makes it SAFE: every site that invalidates
// published state bumps an epoch, EndFrame stamps each scheduled block with the epoch it was
// scheduled under, and a block whose epoch has moved refuses the publish outright — it releases
// the refs it owns and decrements, and the compositor simply keeps the last good pair it had.
// A stale-generation publish is then not "unlikely", it is rejected.
//
// The check is a load, so a bump landing between the check and the stores is possible in
// principle; the drain narrows that from a 200 ms window to a few nanoseconds, which is why the
// drain stays even though it no longer gates anything. Said plainly rather than claimed away.
static atomic_int s_pubEpoch;
static atomic_int s_pubRefused;           // diagnostic: normally 0, reported by EYENOW

static void xr3_zero_slot_readers(void);

static int xr3_invalidate_publishes(void)
{
    // [R9] Nothing published under the old epoch is worth holding a slot for, and a consumer
    // whose release lands after this is clamped at zero rather than wrapping.
    xr3_zero_slot_readers();
    atomic_store(&s_pubSlot, -1);
    // [R14] And the publish fence with them. A pair from a torn-down generation must never
    // leave an event/value behind for the compositor to wait on: the value is already
    // signalled (the listener fired) so it could not hang, but waiting on a dead generation's
    // event is a dependency on nothing, and NULL is the honest statement of "no wait here".
    xr3_pub_set(&s_pubFenceEvent, NULL, false);
    atomic_store(&s_pubFenceValue, 0);
    return atomic_fetch_add(&s_pubEpoch, 1) + 1;
}

// Re-sync the render size to the panel's current aspect (slider release / entry). Engine
// thread only. No-op within 16 px (vkQuake's threshold) or when textures don't exist yet.
extern int  Q2_iOS_ShouldDefer(void);
extern void Q2_iOS_QueueSimple(int kind);
extern int  Q2_iOS_QueueKind_ResizeEyes(void);
void VID_iOS_XR3_ResizeEyes_Now(void);

// Documented engine-thread-only since it was written, and called from the MainActor
// settings sheet — correct only for as long as the engine thread WAS main. Now that VR
// moves it, the public entry point defers through the producer funnel and the real body
// runs at the top of the engine frame.
void VID_iOS_XR3_ResizeEyes(void) {
    if (Q2_iOS_ShouldDefer()) { Q2_iOS_QueueSimple(Q2_iOS_QueueKind_ResizeEyes()); return; }
    VID_iOS_XR3_ResizeEyes_Now();
}

// Arm/disarm the VR depth handoff. Must run before the eye FBOs are wrapped, so the wrap
// picks the right attachment; forcing a re-wrap is how that is guaranteed rather than hoped.
void VID_iOS_XR3_SetVRDepth(int on) {
    if (s_vrDepth == (on != 0)) return;
    s_vrDepth = on != 0;
    // Forcing a re-wrap frees every depth texture (xr3_wrap → xr3_free_depth), so this is the
    // same hazard the resize path has and takes the same drain. It runs at VR entry/exit
    // rather than mid-play, but "no frames in flight here" stopped being true by construction
    // when the producer moved off the main thread — so it is asserted, not assumed.
    // The result is CONSUMED, not discarded (D-VR-R4). This site cannot defer — the exit
    // finalize reaches it after the engine thread is already stopped — so the epoch bump is
    // what makes proceeding safe: any block still outstanding is stamped with the old epoch
    // and will refuse its publish rather than land a pair from the generation being torn down.
    bool drained = xr3_drain_publishes("depth handoff");
    int epoch = xr3_invalidate_publishes();
    for (int e = 0; e < 2; e++) for (int b = 0; b < XR3_EYE_BUFS; b++)
        s_buf[e][b].wrapped = false;
    xr3_pub_set(&s_pubDepth[0], NULL, false);
    xr3_pub_set(&s_pubDepth[1], NULL, false);
    Q2_VR_ConPrintf("xr3: VR depth handoff %s (drain %s, publish epoch %d)\n",
               s_vrDepth ? "ON (per-eye Depth32Float)" : "off",
               drained ? "clean" : "TIMED OUT - late publishes refused", epoch);
}
int VID_iOS_XR3_VRDepthActive(void) { return s_vrDepth; }
void *VID_iOS_XR3_DepthTexture(int eye) { return atomic_load(&s_pubDepth[eye & 1]); }

// The conversion constants the composite needs, taken from what the ENGINE last rendered
// with rather than from what the shell believes: zfar is gl_static.world.size * 2 and
// therefore changes on every map load.
void VID_iOS_XR3_DepthParams(float *znear, float *zfar) {
    if (znear) *znear = q2vr.znear > 0 ? q2vr.znear : 2.0f;
    if (zfar)  *zfar  = q2vr.zfar_used > 0 ? q2vr.zfar_used : 4096.0f;
}

// Engine thread. Sets the VR eye size and re-syncs the renderer to it.
void VID_iOS_XR3_SetVREyeSize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    s_vrForcedW = w; s_vrForcedH = h;
    VID_iOS_XR3_ResizeEyes_Now();
}

void VID_iOS_XR3_ResizeEyes_Now(void) {
    if (!s_buf[0][0].mtl) return;
    int w = 0, h = 0; xr3_target_size(&w, &h);
    if (abs(w - s_buf[0][0].w) <= 16 && abs(h - s_buf[0][0].h) <= 16) { s_resizePending = false; return; }
    // SEQUENCING (D-VR-R3.1). Replacing the ring frees every texture in it, so no completion
    // block may still be holding one when it happens. Before R3 this path only ran during
    // two-phase VR entry, with no frames in flight by construction; the Render Quality
    // slider and `q2vrset vr_quality` made it reachable mid-play, where frames always are.
    // Wait the pending publishes out; if they do not come, keep the CURRENT textures and try
    // again next frame rather than tearing the ring down under them.
    if (!xr3_drain_publishes("resize")) { s_resizePending = true; return; }
    s_resizePending = false;
    // [R19] THE LINE THAT MAKES A RENDER-QUALITY DEATH EXPLAIN ITSELF. The 1.0.11.22
    // report ("a crash while increasing the render quality") produced no .ips and no jetsam
    // entry naming us, and a jetsam kill by construction writes nothing from inside the
    // process. So the footprint on BOTH sides of the ring replacement is recorded here, in
    // the black box, pinned — the resize is the only place the process allocates a gigabyte
    // in one step, and `avail` going to single digits across it names the mechanism outright.
    // Never per-frame: this runs only on a committed size change.
    char memBefore[96] = "";
    Q2_VR_MemLine(memBefore, sizeof memBefore);
    const int oldW = s_buf[0][0].w, oldH = s_buf[0][0].h, oldRing = s_ringActive;
    unsigned readers = 0;
    for (int b = 0; b < XR3_EYE_BUFS; b++) readers += atomic_load(&s_slotReaders[b]);
    xr3_make_textures(MTLCreateSystemDefaultDevice(), w, h, true);
    {
        char memAfter[96] = "";
        Q2_VR_MemLine(memAfter, sizeof memAfter);
        char line[352];
        Q_snprintf(line, sizeof line,
                   "VRRESIZE from=%dx%d/ring%d to=%dx%d/ring%d gen=%d inflight=%d readers=%u "
                   "refused=%d est=%.0fMB before[%s] after[%s]",
                   oldW, oldH, oldRing, w, h, s_ringActive, s_eyeGeneration,
                   atomic_load(&s_inFlight), readers, atomic_load(&s_pubRefused),
                   (double)w * (double)h * 4.0 * (double)(5 * s_ringActive + 6) / (1024.0 * 1024.0),
                   memBefore, memAfter);
        Q2_VR_BlackBoxPin("resize", line);
        Q2_VR_BlackBoxLog(line);
        Q2_VR_ConPrintf("xr3: %s\n", line);
    }
    // A resize re-states r_config from the new EYE size, so the VR panel shape (which is a
    // sub-rect of the old one) is no longer what r_config says. Drop the flag rather than
    // recompute here: the next VR frame calls SetPanelShape unconditionally and it re-applies
    // against the new texture, which keeps one derivation of the rect instead of two.
    s_panelShape = 0; s_panelW = s_panelH = 0; s_hudW = s_hudH = 0; s_hudActive = 0;
    if (q2_xr3_mode) {      // engine renders the new aspect immediately (Hor+ FOV)
        R_ModeChanged(w, h, 0);
        SCR_ModeChanged();
        Q2_VR_ConPrintf("xr3: render re-synced to %dx%d\n", w, h);
    }
}
// The compositor reads the last PUBLISHED (GPU-complete) texture — never the one the
// engine is rendering into. NULL until the first completed frame at the current size.
void *VID_iOS_XR3_EyeTexture(int eye) { return atomic_load(&s_pub[eye & 1]); }

// [R7a item 2] The whole published set, read as ONE consistent snapshot. The compositor uses
// this and nothing else; the single-texture accessors stay for the callers (dumps, readbacks)
// that legitimately want one and do not care about pairing.
//
// Bounded at 8 spins rather than unbounded: this runs inside the compositor's frame, and a
// missed frame is a re-present, while a spin that never ends is a wedged headset. Eight is far
// more than the window needs — a publish is five stores — and on the (never observed) failure
// the caller simply gets the last read, which is exactly what it had before this existed.
void VID_iOS_XR3_AcquirePublished(void **c0, void **c1, void **d0, void **d1, void **ui,
                                  uint64_t *poseId, unsigned *serial, int *slot,
                                  q2_vr_depthconst_t *depthConst,
                                  void **fenceEvent, uint64_t *fenceValue)
{
    for (int spin = 0; spin < 8; spin++) {
        unsigned a = atomic_load(&s_pubSeq);
        if (a & 1u) continue;                       // a publish is mid-flight
        void *lc0 = atomic_load(&s_pub[0]),      *lc1 = atomic_load(&s_pub[1]);
        void *ld0 = atomic_load(&s_pubDepth[0]), *ld1 = atomic_load(&s_pubDepth[1]);
        void *lui = atomic_load(&s_pubUI);
        // [R9] The ring slot and the publish serial ride the SAME seq check as the textures.
        // The slot is what the consumer retains for the life of its command buffer; the serial
        // is what tells it this is a NEW pair (the old `FramesRendered()` gate was read outside
        // the snapshot, so a publish landing in between made the shell sharpen the old pair and
        // stamp the new count — frame N colour with frame N+1 depth and anchor).
        unsigned lser = atomic_load(&s_pubSerial);
        int lslot = atomic_load(&s_pubSlot);
        // [R8] Read INSIDE the same seq check as the textures: an id that could be paired
        // with another frame's pixels is worse than no id at all, because the shell would
        // then submit a confidently wrong anchor.
        uint64_t lid = atomic_load(&s_pubPoseId);
        // [R14] The decode constants and the fence, in the SAME seq check. `zfar_used` changes
        // on every map load and the pair being read is one to three frames old, so a live read
        // of it decodes an old depth buffer against a new map's far plane. The event/value are
        // what the presenting command buffer waits on, and pairing them with another pair's
        // textures would state the wrong dependency.
        q2_vr_depthconst_t ldc = s_pubDepthConst;
        void *lfe = atomic_load(&s_pubFenceEvent);
        uint64_t lfv = atomic_load(&s_pubFenceValue);
        if (atomic_load(&s_pubSeq) != a) continue;  // torn: the set changed under the read
        if (c0) *c0 = lc0;  if (c1) *c1 = lc1;
        if (d0) *d0 = ld0;  if (d1) *d1 = ld1;
        if (ui) *ui = lui;
        if (poseId) *poseId = lid;
        if (serial) *serial = lser;
        if (slot) *slot = lslot;
        if (depthConst) *depthConst = ldc;
        if (fenceEvent) *fenceEvent = lfe;
        if (fenceValue) *fenceValue = lfv;
        return;
    }
    if (c0) *c0 = atomic_load(&s_pub[0]);      if (c1) *c1 = atomic_load(&s_pub[1]);
    if (d0) *d0 = atomic_load(&s_pubDepth[0]); if (d1) *d1 = atomic_load(&s_pubDepth[1]);
    if (ui) *ui = atomic_load(&s_pubUI);
    if (poseId) *poseId = atomic_load(&s_pubPoseId);
    // A torn read must not hand back a slot: retaining the wrong one pins a buffer the engine
    // wants and leaves the one being sampled unprotected. -1 is "no slot", and SlotRetain
    // no-ops on it.
    if (serial) *serial = atomic_load(&s_pubSerial);
    if (slot) *slot = -1;
    // [R14] A torn read hands back NO decode constants and NO fence either, for the same
    // reason it hands back no slot: the caller's live fallback is a known quantity, and a
    // constant set that might belong to another pair is not. zfar = 0 is that signal.
    if (depthConst) { q2_vr_depthconst_t z = {0}; *depthConst = z; }
    if (fenceEvent) *fenceEvent = NULL;
    if (fenceValue) *fenceValue = 0;
}

// Engine thread, before EndFrame: the rendezvous id this frame's eyes were rendered with.
void VID_iOS_XR3_SetFramePoseId(uint64_t id) { atomic_store(&s_framePoseId, id); }
// The id of the pair the compositor is currently presenting (0 before the first publish).
uint64_t VID_iOS_XR3_PublishedPoseId(void) { return atomic_load(&s_pubPoseId); }
int VID_iOS_XR3_FramesRendered(void) { return atomic_load(&s_framesRendered); }
// Current per-eye target size in PHYSICAL pixels (0x0 before the textures exist). Read by
// the EYENOW dump; VR will size these from the drawable's physical colour texture instead
// of the panel pixel budget, and this is the field that proves which one happened.
void VID_iOS_XR3_EyeSize(int *w, int *h) {
    if (w) *w = s_buf[0][0].mtl ? s_buf[0][0].w : 0;
    if (h) *h = s_buf[0][0].mtl ? s_buf[0][0].h : 0;
}
int VID_iOS_XR3_InFlight(void) { return atomic_load(&s_inFlight); }
// The publish epoch and how many completion blocks it has REFUSED (D-VR-R4). `pubrefused` is
// the field that matters: it is 0 on every healthy run, and a non-zero value on a device
// report says a teardown or a resize raced a frame in flight and the guard caught it — which
// is a fact worth having rather than a silence worth trusting.
int VID_iOS_XR3_PubEpoch(void)   { return atomic_load(&s_pubEpoch); }
int VID_iOS_XR3_PubRefused(void) { return atomic_load(&s_pubRefused); }

// ---- engine-side composite readback (the ONLY pixel proof immersive content can give) ----
// The visionOS SIMULATOR cannot composite immersive-space content into `simctl io
// screenshot` — an immersive app screenshots as passthrough plus its 2D window — and even
// on a plain Metal window a grab can come back byte-identical black for both a good and a
// bad build. So the harness reads back what the compositor ACTUALLY samples: the published
// per-eye texture.
//
// The readback is done on the METAL side, never with glReadPixels: these textures are
// MTLStorageModePrivate, and ANGLE's readback path (getBytes on a private texture) faults.
// Blit into a Shared-storage staging texture, wait, then getBytes. Written as PPM (P6) —
// no encoder dependency, and scripts/sim-pixel-count.py reads it directly.
//
// Returns 0 on success. `eye` is 0 or 1; `path` is absolute.
static int xr3_write_ppm(id<MTLTexture> dst, const char *path, int eye);

// Stage one published texture into a Shared-storage copy the CPU can read. `q` and `cb` are
// the caller's, so a PAIR can stage both eyes into ONE command buffer and wait ONCE — which
// matters because the caller holds the engine's ring slot for the whole readback and every
// millisecond of it is a millisecond BeginEye may be blocked.
static id<MTLTexture> xr3_stage_texture(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> src)
{
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                           width:src.width height:src.height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
    if (!dst) return nil;
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(src.width, src.height, 1)
                 toTexture:dst destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    return dst;
}

static int xr3_dump_texture(void *pub, const char *path, int eye)
{
    if (!pub) { Com_EPrintf("q2vrshot: no published eye %d yet\n", eye); return 2; }
    id<MTLTexture> src = (__bridge id<MTLTexture>)pub;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                                                           width:src.width height:src.height
                                                       mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> dst = [dev newTextureWithDescriptor:td];
    if (!dst) return 3;
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0
              sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(src.width, src.height, 1)
                 toTexture:dst destinationSlice:0 destinationLevel:0
         destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    return xr3_write_ppm(dst, path, eye);
}

// The staged (Shared-storage) texture -> P6 on disk. Split out of the single-eye dump so the
// PAIR dump can stage BOTH eyes in one command buffer and wait once.
static int xr3_write_ppm(id<MTLTexture> dst, const char *path, int eye)
{
    const NSUInteger w = dst.width, h = dst.height, stride = w * 4;
    uint8_t *rgba = malloc(stride * h);
    if (!rgba) return 4;
    [dst getBytes:rgba bytesPerRow:stride fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];

    FILE *f = fopen(path, "wb");
    if (!f) { free(rgba); Com_EPrintf("q2vrshot: cannot write %s\n", path); return 5; }
    fprintf(f, "P6\n%lu %lu\n255\n", (unsigned long)w, (unsigned long)h);
    // GL renders bottom-up; write top-down so the PPM matches what a viewer expects and
    // what a --region assertion means by "y".
    for (NSUInteger y = 0; y < h; y++) {
        const uint8_t *row = rgba + (h - 1 - y) * stride;
        for (NSUInteger x = 0; x < w; x++) fwrite(row + x * 4, 1, 3, f);
    }
    fclose(f);
    free(rgba);
    Q2_VR_ConPrintf("q2vrshot: eye %d %lux%lu -> %s\n", eye, (unsigned long)w, (unsigned long)h, path);
    return 0;
}

int Q2_VR_EyeShot(int eye, const char *path)
{
    // eye 2 is the 2D-redirect UI texture. Same readback, same publish step, so a suite can
    // assert "the HUD is on the UI surface" and "the eye image no longer carries it" from
    // two shots of the SAME frame rather than from two runs.
    if (!path || eye < 0 || eye > 2) return 1;
    return xr3_dump_texture(eye == 2 ? atomic_load(&s_pubUI) : atomic_load(&s_pub[eye]), path, eye);
}

// [R8] BOTH EYES OF ONE PUBLISHED PAIR. Two separate `q2vrshot` commands read `s_pub` at two
// different moments, so anything measured across them carries the scene's own change between
// those moments — which is fatal for a LEFT-VS-RIGHT assertion: during a firefight the frame
// brightness moves by more than a whole luma unit between consecutive publishes, swamping the
// per-eye difference the assertion is about. This takes the pair through the compositor's own
// seqlock reader, so the two images are the two halves of ONE frame, and then dumps them.
int Q2_VR_EyeShotPair(const char *path0, const char *path1)
{
    if (!path0 || !path1) return 1;
    // [R9] The acquire is atomic but the two readbacks are sequential, so without holding the
    // slot the ring could recycle between them and the "pair" would be two different frames —
    // the same hazard the compositor has, fixed with the same primitive.
    void *c0 = NULL, *c1 = NULL;
    int slot = -1;
    VID_iOS_XR3_AcquirePublished(&c0, &c1, NULL, NULL, NULL, NULL, NULL, &slot,
                                 NULL, NULL, NULL);
    if (!c0 || !c1) { Com_EPrintf("q2vrshot: no published pair yet\n"); return 2; }
    // Retain IMMEDIATELY after the acquire (review R9): device/queue creation below is not
    // free, and an unretained gap there is the very window the engine's reader gate cannot see.
    VID_iOS_XR3_SlotRetain(slot);
    // ONE command buffer, ONE wait, and the ring slot held across it. Two sequential
    // blit-and-wait readbacks at eye resolution stalled the producer for long enough to spike
    // the publish lag past the shell's anchor ring (R8-3 fell over on exactly that), and they
    // could recycle the ring between them, which is the tear this retain exists to stop.
    // The PPM writes happen AFTER the slot is released: they touch only the staged copies.
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLTexture> s0 = xr3_stage_texture(dev, cb, (__bridge id<MTLTexture>)c0);
    id<MTLTexture> s1 = xr3_stage_texture(dev, cb, (__bridge id<MTLTexture>)c1);
    [cb commit];
    [cb waitUntilCompleted];
    VID_iOS_XR3_SlotRelease(slot);
    if (!s0 || !s1) return 3;
    int rc0 = xr3_write_ppm(s0, path0, 0);
    int rc1 = xr3_write_ppm(s1, path1, 1);
    return rc0 ? rc0 : rc1;
}

// [R11] PER-EYE DEPTH READBACK — the instrument for "is the LEFT eye's published DEPTH the
// depth it rendered?".
//
// visionOS reprojects each submitted eye against the depth we hand it, so a depth attachment
// that ANGLE-Metal lost, cleared or stored as DontCare around an interrupted render pass
// produces a per-eye wobble on every head motion that no colour readback can see — and eye 0
// is the one eye whose pass IS interrupted (the 2D redirect binds another framebuffer in the
// middle of it). Two correct eyes differ only by parallax, so `absdiff_mean` is small; a
// stale, cleared or garbage eye reads large, or saturates at 0 or 1.
//
// Read from the PUBLISHED pair — s_pubDepth, through the same seqlock the compositor reads
// and with the ring slot held across the blit — because that is the memory the compositor's
// private copies are made FROM. Copying the compositor's own privDepth would measure the copy
// rather than what was published, and privDepth is Swift-side and per-frame transient.
//
// THE COPY IS A COMPUTE KERNEL, not a blit, and that is not a style choice: the R0 depth
// spike recorded (xr3_depth_spike.m) that "a blit or getBytes on a depth texture is not a
// supported copy on this backend and aborts the process". It does not abort here — it
// silently produces ZEROS, which is worse, because an instrument that reads 100 % zero depth
// looks exactly like the fault it was written to find. So the depth is READ, texel by texel,
// by the same operation the compositor performs on it, into a shared buffer of floats.
static float xr3_depth_at(const float *base, NSUInteger w, NSUInteger x, NSUInteger y)
{
    return base[y * w + x];
}

// One staged depth buffer -> a 16-bit PGM (P5, maxval 65535, big-endian), top-down so the
// image matches what a viewer expects and what a --region assertion means by "y" — the same
// flip xr3_write_ppm does, for the same reason.
static int xr3_write_pgm16(const float *base, NSUInteger w, NSUInteger h, const char *path)
{
    FILE *f = fopen(path, "wb");
    if (!f) { Com_EPrintf("q2vrdepthshot: cannot write %s\n", path); return 5; }
    fprintf(f, "P5\n%lu %lu\n65535\n", (unsigned long)w, (unsigned long)h);
    uint16_t *row = malloc(w * sizeof(uint16_t));
    if (!row) { fclose(f); return 4; }
    for (NSUInteger y = 0; y < h; y++) {
        NSUInteger sy = h - 1 - y;
        for (NSUInteger x = 0; x < w; x++) {
            float d = xr3_depth_at(base, w, x, sy);
            if (!(d >= 0.0f)) d = 0.0f;          // NaN-safe
            if (d > 1.0f) d = 1.0f;
            uint16_t v = (uint16_t)lroundf(d * 65535.0f);
            row[x] = (uint16_t)((v >> 8) | (v << 8));   // PGM is big-endian
        }
        fwrite(row, sizeof(uint16_t), w, f);
    }
    free(row);
    fclose(f);
    return 0;
}


// [R12] THE GL-SIDE DEPTH PROBE. The R11 finding ("published depth is NaN/zero in every
// texel") has two utterly different causes and no Metal-side reading can separate them:
// either GL never rendered depth into the wrapped texture at all, or GL did and the value
// is not VISIBLE to Metal (a store action, a synchronisation, a different texture).
// This asks GL itself, with the engine's own context current, what the depth texture of the
// last-rendered slot holds — sampled exactly the way a GL shader would sample it. It writes
// into a 2x1 RGBA8 target: texel 0 carries the depth packed to 24 bits, texel 1 carries the
// three predicates (isnan, ==1, ==0) that an 8-bit channel could not otherwise express.
static GLuint s_probeFbo, s_probeTex, s_probeProg, s_probeVao;
static GLint  s_probeLoc = -1;

static GLuint xr3_probe_shader(GLenum type, const char *src)
{
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[512] = ""; glGetShaderInfoLog(s, sizeof log, NULL, log);
               Com_EPrintf("xr3: depth probe shader: %s\n", log); glDeleteShader(s); return 0; }
    return s;
}

static bool xr3_probe_init(void)
{
    if (s_probeProg) return true;
    static const char *vs =
        "#version 300 es\n"
        "void main(){ vec2 p[3]; p[0]=vec2(-1.0,-1.0); p[1]=vec2(3.0,-1.0); p[2]=vec2(-1.0,3.0);\n"
        "  gl_Position = vec4(p[gl_VertexID], 0.0, 1.0); }\n";
    static const char *fs =
        "#version 300 es\n"
        "precision highp float;\n"
        "uniform highp sampler2D uDepth;\n"
        "out vec4 fragColor;\n"
        "void main(){\n"
        "  float d = texture(uDepth, vec2(0.5, 0.5)).r;\n"
        "  if (gl_FragCoord.x < 1.0) {\n"
        "    vec3 e = fract(vec3(1.0, 255.0, 65025.0) * d);\n"
        "    e -= vec3(e.y, e.z, 0.0) * (1.0/255.0);\n"
        "    fragColor = vec4(e, 1.0);\n"
        "  } else {\n"
        "    fragColor = vec4(isnan(d) ? 1.0 : 0.0, d >= 1.0 ? 1.0 : 0.0,\n"
        "                     d <= 0.0 ? 1.0 : 0.0, 1.0);\n"
        "  }\n"
        "}\n";
    GLuint v = xr3_probe_shader(GL_VERTEX_SHADER, vs), f = xr3_probe_shader(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return false;
    GLuint prog = glCreateProgram();
    glAttachShader(prog, v); glAttachShader(prog, f); glLinkProgram(prog);
    GLint ok = 0; glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    glDeleteShader(v); glDeleteShader(f);
    if (!ok) { char log[512] = ""; glGetProgramInfoLog(prog, sizeof log, NULL, log);
               Com_EPrintf("xr3: depth probe link: %s\n", log); glDeleteProgram(prog); return false; }
    glGenTextures(1, &s_probeTex); glBindTexture(GL_TEXTURE_2D, s_probeTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 2, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glGenFramebuffers(1, &s_probeFbo); glBindFramebuffer(GL_FRAMEBUFFER, s_probeFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, s_probeTex, 0);
    glGenVertexArrays(1, &s_probeVao);
    s_probeProg = prog;
    s_probeLoc = glGetUniformLocation(prog, "uDepth");
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return true;
}

// Returns the GL-sampled centre depth of s_buf[eye][slot]'s depth texture, or -1 when the
// probe could not run; `flags` gets bit0=isnan bit1=one bit2=zero.
static float xr3_gl_depth_probe(int eye, int slot, int *flags)
{
    if (flags) *flags = 0;
    if (eye < 0 || eye > 1 || slot < 0 || slot >= XR3_EYE_BUFS) return -1.0f;
    GLuint dt = s_buf[eye][slot].depthTex;
    if (!dt || !xr3_probe_init()) return -1.0f;
    GLint prevFbo = 0; glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_probeFbo);
    glViewport(0, 0, 2, 1);
    glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST); glDisable(GL_BLEND);
    glDisable(GL_CULL_FACE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glUseProgram(s_probeProg);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, dt);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
    glUniform1i(s_probeLoc, 0);
    glBindVertexArray(s_probeVao);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    unsigned char px[8] = { 0 };
    glReadPixels(0, 0, 2, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindVertexArray(0);
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    if (flags) *flags = (px[4] > 127 ? 1 : 0) | (px[5] > 127 ? 2 : 0) | (px[6] > 127 ? 4 : 0);
    return px[0] / 255.0f + px[1] / 65025.0f + px[2] / 16581375.0f;
}

// The engine-side render state the depth answer depends on: with bloom or waterwarp on the
// renderer draws the WORLD into its own FBO_SCENE (its own DEPTH24_STENCIL8 renderbuffer)
// and only composites the colour into our eye FBO, so our depth texture would never be
// written no matter how well the wrap works. Reported with every VRDEPTH line so the two
// causes are never confused again.
static void xr3_depth_context(char *out, int outsz)
{
    Q_snprintf(out, outsz, "gl_bloom=%d gl_waterwarp=%d lastslot=%d",
               (int)Cvar_VariableValue("gl_bloom"), (int)Cvar_VariableValue("gl_waterwarp"),
               (s_ping + s_ringActive - 1) % s_ringActive);
}

int Q2_VR_DepthShotPair(const char *path0, const char *path1, char *line, int linesz)
{
    if (!path0 || !path1) return 1;
    if (line && linesz > 0) line[0] = 0;
    // [R12] Ask GL first, on the engine thread, before anything Metal-side runs: this is the
    // only reading that can tell "GL never wrote depth here" apart from "GL wrote it and
    // Metal cannot see it", and it costs one 2x1 draw.
    const int lastSlot = (s_ping + s_ringActive - 1) % s_ringActive;
    int gf0 = 0, gf1 = 0;
    const float gd0 = xr3_gl_depth_probe(0, lastSlot, &gf0);
    const float gd1 = xr3_gl_depth_probe(1, lastSlot, &gf1);
    char ctx[96]; xr3_depth_context(ctx, sizeof ctx);
    void *d0 = NULL, *d1 = NULL;
    int slot = -1;
    VID_iOS_XR3_AcquirePublished(NULL, NULL, &d0, &d1, NULL, NULL, NULL, &slot,
                                 NULL, NULL, NULL);
    if (!d0 || !d1) { Com_EPrintf("q2vrdepthshot: no published depth pair yet\n"); return 2; }
    // Retain IMMEDIATELY after the acquire, as the pair colour shot does: device and queue
    // creation below is not free, and an unretained gap there is exactly the window the
    // engine's reader gate cannot see.
    VID_iOS_XR3_SlotRetain(slot);
    id<MTLTexture> t0 = (__bridge id<MTLTexture>)d0, t1 = (__bridge id<MTLTexture>)d1;
    const NSUInteger w = t0.width, h = t0.height;
    if (t1.width != w || t1.height != h) { VID_iOS_XR3_SlotRelease(slot); return 6; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    // Built here rather than cached: this runs once, by hand, from a console command, and a
    // pipeline living across a device teardown is a hazard for no gain.
    id<MTLLibrary> lib = [dev newLibraryWithSource:
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         // depth2d, NOT texture2d: a Depth32Float texture bound as texture2d reads back as
         // ZERO on this backend, silently and with no validation error — which is exactly the
         // reading a lost depth attachment would produce, so the instrument would "find" its
         // own bug on every run. SAMPLED with the same nearest sampler the composite's
         // q2eyefrag uses, so what this measures is what the compositor actually reads; the
         // two probe slots at the end read the CENTRE texel both ways, so a future zero can be
         // told apart from an access-mode fault without another build.
         "kernel void q2_depthgrab(depth2d<float, access::sample> d0 [[texture(0)]],\n"
         "                         depth2d<float, access::sample> d1 [[texture(1)]],\n"
         "                         device float *out [[buffer(0)]],\n"
         "                         constant uint2 &dim [[buffer(1)]],\n"
         "                         uint2 gid [[thread_position_in_grid]]) {\n"
         "  constexpr sampler ds(filter::nearest, address::clamp_to_edge);\n"
         "  if (gid.x >= dim.x || gid.y >= dim.y) return;\n"
         "  uint n = dim.x * dim.y;\n"
         "  uint i = gid.y * dim.x + gid.x;\n"
         "  float2 uv = (float2(gid) + 0.5) / float2(dim);\n"
         "  out[i]     = d0.sample(ds, uv);\n"
         "  out[n + i] = d1.sample(ds, uv);\n"
         "  if (i == 0) {\n"
         "    uint2 c = dim / 2;\n"
         "    float2 cuv = (float2(c) + 0.5) / float2(dim);\n"
         "    out[2 * n + 0] = d0.read(c);\n"
         "    out[2 * n + 1] = d0.sample(ds, cuv);\n"
         "    out[2 * n + 2] = d0.get_width();\n"
         "    out[2 * n + 3] = d0.get_height();\n"
         "  }\n"
         "}\n" options:nil error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"q2_depthgrab"];
    id<MTLComputePipelineState> pso = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    id<MTLBuffer> buf = pso ? [dev newBufferWithLength:(2 * w * h + 4) * sizeof(float)
                                               options:MTLResourceStorageModeShared] : nil;
    if (!buf) {
        VID_iOS_XR3_SlotRelease(slot);
        Com_EPrintf("q2vrdepthshot: no depth-read pipeline (%s)\n",
                    err.localizedDescription.UTF8String ?: "(none)");
        return 3;
    }
    // ONE command buffer, ONE wait, the slot held across it — the producer is blocked in
    // BeginEye for every millisecond of this, so both eyes go in together.
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    simd_uint2 dim = { (uint32_t)w, (uint32_t)h };
    [ce setComputePipelineState:pso];
    [ce setTexture:t0 atIndex:0];
    [ce setTexture:t1 atIndex:1];
    [ce setBuffer:buf offset:0 atIndex:0];
    [ce setBytes:&dim length:sizeof(dim) atIndex:1];
    [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [ce endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    VID_iOS_XR3_SlotRelease(slot);

    const float *p[2] = { (const float *)buf.contents, (const float *)buf.contents + w * h };
    const float *probe = (const float *)buf.contents + 2 * w * h;
    double mean[2] = { 0, 0 }, absdiff = 0.0;
    float mn[2] = { 1.0f, 1.0f }, mx[2] = { 0.0f, 0.0f };
    unsigned long zero[2] = { 0, 0 }, one[2] = { 0, 0 };
    const double n = (double)w * (double)h;
    for (NSUInteger y = 0; y < h; y++) {
        for (NSUInteger x = 0; x < w; x++) {
            float v[2];
            for (int e = 0; e < 2; e++) {
                float d = xr3_depth_at(p[e], w, x, y);
                if (!(d >= 0.0f)) d = 0.0f;
                if (d > 1.0f) d = 1.0f;
                v[e] = d;
                mean[e] += d;
                if (d < mn[e]) mn[e] = d;
                if (d > mx[e]) mx[e] = d;
                if (d <= 1e-6f) zero[e]++;
                else if (d >= 1.0f - 1e-6f) one[e]++;
            }
            absdiff += fabs((double)v[0] - (double)v[1]);
        }
    }
    if (line && linesz > 0) {
        Q_snprintf(line, linesz,
                   "VRDEPTH e0 min=%.6f max=%.6f mean=%.6f zero%%=%.2f one%%=%.2f "
                   "e1 min=%.6f max=%.6f mean=%.6f zero%%=%.2f one%%=%.2f "
                   "absdiff_mean=%.6f size=%lux%lu probe_read=%.6f probe_sample=%.6f "
                   "probe_dim=%.0fx%.0f gl_e0=%.6f gl_e0f=%d gl_e1=%.6f gl_e1f=%d %s path=%s",
                   mn[0], mx[0], mean[0] / n, 100.0 * zero[0] / n, 100.0 * one[0] / n,
                   mn[1], mx[1], mean[1] / n, 100.0 * zero[1] / n, 100.0 * one[1] / n,
                   absdiff / n, (unsigned long)w, (unsigned long)h,
                   probe[0], probe[1], probe[2], probe[3],
                   gd0, gf0, gd1, gf1, ctx, path0);
    }
    // The PGM writes touch only the staged copies, so they happen AFTER the slot is released.
    int rc0 = xr3_write_pgm16(p[0], w, h, path0);
    int rc1 = xr3_write_pgm16(p[1], w, h, path1);
    return rc0 ? rc0 : rc1;
}

// Enter/leave stereo (engine thread). On enter the engine's render size becomes the eye
// texture size; on exit it returns to the window surface size. Window never touched in 3D.
void VID_iOS_XR3_SetMode(int on) {
    if (q2_xr3_mode == !!on) return;
    if (on) xr3_ensure_textures();
    if (on && (!s_buf[0][0].mtl || !s_buf[1][0].mtl)) { Com_EPrintf("xr3: no eye textures\n"); return; }
    // BOTH directions drain. Leaving stereo without one strands scheduled blocks that would
    // publish into a dead session; entering while any survive would let their late decrement
    // drive the counter below zero past the reset just below, which silently disables the
    // in-flight gate — the unbounded-producer bug this ring was built to end. The clamp in
    // the block is the second guard on that.
    // Consumed, not discarded (D-VR-R4), and for the same reason as the depth site above: this
    // one cannot defer either — the exit direction is the teardown finalize itself. The epoch
    // bump is what makes the unconditional proceed safe, and it matters most exactly here,
    // because the `on` branch RESETS s_inFlight to 0 and a surviving block's late decrement
    // would otherwise be absorbed only by the clamp inside it.
    bool drained = xr3_drain_publishes(on ? "stereo enter" : "stereo exit");
    int epoch = xr3_invalidate_publishes();
    if (!drained)
        Com_EPrintf("xr3: stereo %s proceeding with publishes in flight - epoch %d refuses them\n",
                    on ? "enter" : "exit", epoch);
    q2_xr3_mode = !!on;
    if (on) {
        // Panel draws passthrough-only until a fresh frame publishes.
        xr3_pub_set(&s_pub[0], NULL, false);
        xr3_pub_set(&s_pub[1], NULL, false);
        xr3_pub_set(&s_pubDepth[0], NULL, false);
        xr3_pub_set(&s_pubDepth[1], NULL, false);
        atomic_store(&s_framesRendered, 0);
        atomic_store(&s_pubPoseId, 0);   // [R8] see above
        atomic_store(&s_inFlight, 0);
        xr3_zero_slot_readers();         // [R9] no consumer can hold a slot of a dead session
        atomic_store(&s_pubSlot, -1);
        atomic_store(&s_slotFrames, 0);
        atomic_store(&s_slotWaits, 0);
        atomic_store(&s_slotHeals, 0);
        s_ping = 0;
        s_resizePending = false;
        s_panelShape = 0; s_panelW = s_panelH = 0; s_hudW = s_hudH = 0; s_hudActive = 0;
        R_ModeChanged(s_buf[0][0].w, s_buf[0][0].h, 0);
        SCR_ModeChanged();
        Q2_VR_ConPrintf("xr3: stereo ON (%dx%d per eye, ring-%d, max 2 in flight)\n",
                   s_buf[0][0].w, s_buf[0][0].h, s_ringActive);
    } else {
        s_panelShape = 0; s_panelW = s_panelH = 0; s_hudW = s_hudH = 0; s_hudActive = 0;
        // [R7a item 12] FIRST, before any GL call below: put the EGL window surface back
        // under this context. A VR session hands the context to the engine thread and takes
        // it back surfaceless (the acquire runs while q2_xr3_mode is still 1), and nothing
        // else in the app ever re-binds it — so without this line every eglSwapBuffers after
        // a VR exit fails and the 2D window is frozen forever while audio keeps playing.
        // Here rather than in the exit finalize because every path that reaches "stereo off"
        // needs it, including the failed-entry rollback and the Digital Crown belt.
        VID_iOS_ANGLE_BindWindowSurface();
        xr3_ms_free();     // [R20] no eye is being rendered: nothing may hold the MS buffers
        V_SetStereoOffset(0);
        R_SetDefaultFramebuffer(0);
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        int w = 0, h = 0; VID_iOS_XR3_GetWindowSize(&w, &h);
        if (w && h) { R_ModeChanged(w, h, 0); SCR_ModeChanged(); }
        Q2_VR_ConPrintf("xr3: stereo OFF\n");
    }
}

// Per-eye begin (engine thread): stereo matrices + this eye's CURRENT PING FBO as the
// default framebuffer. Eye 0 first applies the frames-in-flight bound: never start a
// new stereo frame while 2 are still on the GPU (vkQuake's vkWaitForFences discipline,
// which the 3D path lost when it gated off eglSwapBuffers — ANGLE's only built-in
// backpressure). Without this the display link free-runs the producer and the command
// queue grows without bound: seconds of latency, hitching, GPU saturation, jetsam.
// =====================================================================================
// [R21] THE GPU TIMER — the perf question cannot be answered without it
// =====================================================================================
// "The game looks better at 1.75 and higher but gets choppy" has exactly two mechanisms and
// nothing in this repo could tell them apart: either the engine's CPU frame no longer fits
// the layer period, or its GPU work does not. Every number the campaign has is CPU-side
// (host frame intervals, late counts), so every perf conclusion so far has been an
// inference. This is the missing half.
//
// GL_EXT_disjoint_timer_query, ONE query per HOST FRAME (both eyes plus the UI pass), begun
// at the end of the frame's first BeginEye — after the in-flight and eye-slot gates, so a
// CPU stall waiting for the ring is not charged to the GPU — and ended in EndFrame before
// the publish sync. Results are read back several frames later from a ring: never
// `glGetQueryObject` on the query just ended, which is a full GPU stall and would make the
// instrument the cost it is measuring.
//
// FALLS BACK LOUDLY. ANGLE-Metal is expected to export the extension; if the runtime string
// does not carry it the probe says so once, on the console and in the black box, and
// `eng_ms` reads 0.00 rather than a plausible fiction.
// GL_GPU_DISJOINT_EXT is checked at readback: a disjoint interval means the GPU clock was
// interrupted and every outstanding result is garbage, so the whole ring is dropped.

#ifndef GL_TIME_ELAPSED_EXT
#define GL_TIME_ELAPSED_EXT              0x88BF
#endif
#ifndef GL_QUERY_RESULT_EXT
#define GL_QUERY_RESULT_EXT              0x8866
#endif
#ifndef GL_QUERY_RESULT_AVAILABLE_EXT
#define GL_QUERY_RESULT_AVAILABLE_EXT    0x8867
#endif
#ifndef GL_GPU_DISJOINT_EXT
#define GL_GPU_DISJOINT_EXT              0x8FBB
#endif

typedef void (GL_APIENTRYP XR3_PFNGENQUERIES)(GLsizei n, GLuint *ids);
typedef void (GL_APIENTRYP XR3_PFNDELQUERIES)(GLsizei n, const GLuint *ids);
typedef void (GL_APIENTRYP XR3_PFNBEGINQUERY)(GLenum target, GLuint id);
typedef void (GL_APIENTRYP XR3_PFNENDQUERY)(GLenum target);
typedef void (GL_APIENTRYP XR3_PFNGETQOUIV)(GLuint id, GLenum pname, GLuint *params);
typedef void (GL_APIENTRYP XR3_PFNGETQOUI64V)(GLuint id, GLenum pname, GLuint64 *params);

#define XR3_GPUQ_RING 4

static XR3_PFNGENQUERIES  s_qGen;
static XR3_PFNDELQUERIES  s_qDel;
static XR3_PFNBEGINQUERY  s_qBegin;
static XR3_PFNENDQUERY    s_qEnd;
static XR3_PFNGETQOUIV    s_qGetuiv;
static XR3_PFNGETQOUI64V  s_qGetui64v;
static int      s_gpuqState;                 // 0 = unprobed, 1 = ready, -1 = unavailable
static EGLContext s_gpuqCtx;                 // the context the query names belong to
static GLuint   s_gpuq[XR3_GPUQ_RING];
static int      s_gpuqHead, s_gpuqCount;     // ring of queries awaiting a result
static int      s_gpuqActive = -1;           // index of the query currently open, -1 = none

static void xr3_gpuq_shutdown(void)
{
    if (s_qDel && s_gpuq[0]) s_qDel(XR3_GPUQ_RING, s_gpuq);
    memset(s_gpuq, 0, sizeof s_gpuq);
    s_gpuqHead = s_gpuqCount = 0;
    s_gpuqActive = -1;
    s_gpuqCtx = EGL_NO_CONTEXT;
    s_gpuqState = 0;
}

// Engine thread, context current.
static void xr3_gpuq_probe(void)
{
    EGLContext cur = eglGetCurrentContext();
    if (s_gpuqState != 0 && cur == s_gpuqCtx) return;
    if (s_gpuqState != 0) xr3_gpuq_shutdown();      // the context changed: the names are gone
    const char *ext = (const char *)glGetString(GL_EXTENSIONS);
    while (glGetError() != GL_NO_ERROR) { }
    if (!ext || !strstr(ext, "GL_EXT_disjoint_timer_query")) {
        s_gpuqState = -1;
        s_gpuqCtx = cur;
        Q2_VR_ConPrintf("xr3: GPU timer UNAVAILABLE - GL_EXT_disjoint_timer_query is not in "
                        "GL_EXTENSIONS; VRGPU eng_ms will read 0.00\n");
        Q2_VR_NoteGpuTimerUnavailable();
        return;
    }
    s_qGen      = (XR3_PFNGENQUERIES) eglGetProcAddress("glGenQueriesEXT");
    s_qDel      = (XR3_PFNDELQUERIES) eglGetProcAddress("glDeleteQueriesEXT");
    s_qBegin    = (XR3_PFNBEGINQUERY) eglGetProcAddress("glBeginQueryEXT");
    s_qEnd      = (XR3_PFNENDQUERY)   eglGetProcAddress("glEndQueryEXT");
    s_qGetuiv   = (XR3_PFNGETQOUIV)   eglGetProcAddress("glGetQueryObjectuivEXT");
    s_qGetui64v = (XR3_PFNGETQOUI64V) eglGetProcAddress("glGetQueryObjectui64vEXT");
    if (!s_qGen || !s_qDel || !s_qBegin || !s_qEnd || !s_qGetuiv || !s_qGetui64v) {
        // The string advertised it and the entry points are not there. That is a backend
        // bug, not a capability answer, and it gets its own message.
        s_gpuqState = -1;
        s_gpuqCtx = cur;
        Q2_VR_ConPrintf("xr3: GPU timer UNAVAILABLE - the extension string advertises "
                        "GL_EXT_disjoint_timer_query but eglGetProcAddress returned no entry "
                        "points; VRGPU eng_ms will read 0.00\n");
        Q2_VR_NoteGpuTimerUnavailable();
        return;
    }
    s_qGen(XR3_GPUQ_RING, s_gpuq);
    if (glGetError() != GL_NO_ERROR || !s_gpuq[0]) {
        s_gpuqState = -1;
        s_gpuqCtx = cur;
        Q2_VR_ConPrintf("xr3: GPU timer UNAVAILABLE - glGenQueriesEXT failed\n");
        Q2_VR_NoteGpuTimerUnavailable();
        return;
    }
    s_gpuqState = 1;
    s_gpuqCtx = cur;
    s_gpuqHead = s_gpuqCount = 0;
    s_gpuqActive = -1;
    Q2_VR_ConPrintf("xr3: GPU timer ready (GL_EXT_disjoint_timer_query, %d-deep ring, "
                    "one TIME_ELAPSED query per host frame)\n", XR3_GPUQ_RING);
}

// The end of the frame's FIRST BeginEye. A frame whose ring is full simply goes unmeasured —
// the instrument never blocks the producer.
static void xr3_gpuq_begin(void)
{
    xr3_gpuq_probe();
    if (s_gpuqState != 1 || s_gpuqActive >= 0) return;
    if (s_gpuqCount >= XR3_GPUQ_RING) return;
    int idx = (s_gpuqHead + s_gpuqCount) % XR3_GPUQ_RING;
    s_qBegin(GL_TIME_ELAPSED_EXT, s_gpuq[idx]);
    if (glGetError() != GL_NO_ERROR) return;      // refused: leave the slot unclaimed
    s_gpuqActive = idx;
}

// EndFrame, before the publish sync. Closes this frame's query and drains whatever the GPU
// has finished — never a wait, never a result read on the query just closed.
static void xr3_gpuq_end(void)
{
    if (s_gpuqState != 1) return;
    if (s_gpuqActive >= 0) {
        s_qEnd(GL_TIME_ELAPSED_EXT);
        while (glGetError() != GL_NO_ERROR) { }
        s_gpuqCount++;
        s_gpuqActive = -1;
    }
    GLint disjoint = 0;
    glGetIntegerv(GL_GPU_DISJOINT_EXT, &disjoint);
    while (glGetError() != GL_NO_ERROR) { }
    if (disjoint) {                     // the GPU clock was interrupted: every result is junk
        s_gpuqHead = (s_gpuqHead + s_gpuqCount) % XR3_GPUQ_RING;
        s_gpuqCount = 0;
        return;
    }
    while (s_gpuqCount > 0) {
        GLuint avail = 0;
        s_qGetuiv(s_gpuq[s_gpuqHead], GL_QUERY_RESULT_AVAILABLE_EXT, &avail);
        if (glGetError() != GL_NO_ERROR || !avail) break;
        GLuint64 ns = 0;
        s_qGetui64v(s_gpuq[s_gpuqHead], GL_QUERY_RESULT_EXT, &ns);
        while (glGetError() != GL_NO_ERROR) { }
        Q2_VR_NoteEngineGpu((double)ns / 1e6);
        s_gpuqHead = (s_gpuqHead + 1) % XR3_GPUQ_RING;
        s_gpuqCount--;
    }
}

void VID_iOS_XR3_BeginEye(int eye, float halfSep, float convergence) {
    if (!q2_xr3_mode) return;
    // [R20] The PREVIOUS eye's MSAA resolve, before this one touches the shared MS buffer.
    // First thing in the function, ahead of the gates below: the resolve is GPU work and the
    // sooner it is submitted the more of it overlaps the wait.
    xr3_ms_resolve();
    if (eye == 0 && atomic_load(&s_inFlight) >= 2) {
        int spins = 0;
        while (atomic_load(&s_inFlight) >= 2 && ++spins < 400) usleep(500);   // ≤200 ms
        if (spins >= 400) {   // GPU wedged or a completion was lost — self-heal, loudly
            // Bump the epoch with the reset (D-VR-R4). This is the third place the in-flight
            // counter is deliberately lied to, and a block that fires after it is by definition
            // at least 200 ms stale: its frame is long gone, so publishing it would put an old
            // pair in front of a newer one. Refusing leaves the last good pair up, which is the
            // right failure for a path that is already a disaster path.
            Com_EPrintf("xr3: in-flight gate timed out, resetting (publish epoch %d)\n",
                        xr3_invalidate_publishes());
            atomic_store(&s_inFlight, 0);
        }
    }
    // [R9 item 1] THE READER GATE. The in-flight gate above bounds how far ahead the producer
    // may run; this one bounds which BUFFER it may run into. A consumer holds the slot it
    // acquired for the life of the command buffer that samples it, so waiting here is what
    // makes "the engine overwrote the pair the compositor was reading" impossible rather than
    // merely unlikely. It is a WAIT, never a silent stall: the timeout self-heals exactly as
    // the in-flight gate does, loudly, and the count is reported every second as VRSLOT.
    if (eye == 0) {
        atomic_fetch_add(&s_slotFrames, 1);
        if (atomic_load(&s_slotReaders[s_ping]) > 0u) {
            atomic_fetch_add(&s_slotWaits, 1);
            int spins = 0;
            while (atomic_load(&s_slotReaders[s_ping]) > 0u && ++spins < 400) usleep(500);  // <=200 ms
            if (spins >= 400) {
                // A consumer never released. Its command buffer is 200 ms gone either way, so
                // the honest recovery is the in-flight gate's: say so, refuse every publish
                // scheduled under the old epoch, and clear the readers (xr3_invalidate_publishes
                // does the clearing). Never a silent proceed — that is the write-under-read this
                // gate exists to prevent.
                Com_EPrintf("xr3: eye-slot reader gate timed out on slot %d, resetting (publish epoch %d)\n",
                            s_ping, xr3_invalidate_publishes());
                atomic_fetch_add(&s_slotHeals, 1);
            }
        }
    }
    // A resize whose drain timed out retries HERE, at the top of the next frame and after the
    // in-flight gate (so the queue has had its best chance to empty). Without this the 3D
    // panel path would silently keep the old size forever: its resize arrives once, through
    // the producer funnel, and nothing re-requests it. The VR path re-requests every frame
    // from vr_engine_frame, so for it this is merely the earlier of two chances.
    if (eye == 0 && s_resizePending) VID_iOS_XR3_ResizeEyes_Now();
    if (eye == 0) s_uiCleared = false;   // the UI target is cleared once per HOST FRAME
    GLuint fbo = xr3_wrap(eye & 1, s_ping);
    if (!fbo) return;
    // [R20] MSAA. The engine draws into the SHARED multisampled FBO and the wrapped eye
    // texture receives a resolve at the end of this eye (the next BeginEye, or EndFrame).
    // Everything downstream — the ring, the publish, the compositor — still sees exactly the
    // same eye texture it always did, which is why MSAA needed no changes to any of them.
    GLuint draw = fbo;
    const int ew = s_buf[eye & 1][s_ping].w, eh = s_buf[eye & 1][s_ping].h;
    const int samples = xr3_ms_samples();
    if (samples >= 2 && xr3_ms_ensure(ew, eh, samples)) {
        draw = s_msFbo;
        s_msPendingDst   = fbo;
        s_msPendingW     = ew;
        s_msPendingH     = eh;
        // Only route A publishes depth. Without a depth TEXTURE on the eye FBO the depth
        // resolve would target the shared scratch renderbuffer, which nobody reads.
        s_msPendingDepth = s_vrDepth && s_buf[eye & 1][s_ping].depthTex != 0;
    } else if (s_msFbo) {
        xr3_ms_free();      // turned off (or refused): give the 65-130 MB back this frame
    }
    s_currentEyeFbo = draw;              // what VID_iOS_XR3_UIEnd binds back to
    V_SetStereoConvergence(convergence);
    V_SetStereoOffset(eye == 0 ? -halfSep : +halfSep);
    R_SetDefaultFramebuffer(draw);
    glBindFramebuffer(GL_FRAMEBUFFER, draw);
    if (s_panelShape) {
        // With the panel shape on, the engine only writes the 16:9 sub-rect, and the rest of
        // the texture still holds whatever the last WORLD frame left there. The compositor
        // samples only the sub-rect, so those pixels are never seen — but a 2D frame that
        // does not paint its own background (the console over a disconnected client) would
        // show the previous frame inside the rect too. One clear of the whole target, on the
        // path that is already the cheap one because no world is being drawn.
        // glClear ignores the viewport but honours the SCISSOR, and the engine's own
        // GL_Setup2D disables it at the top of every 2D pass anyway; the clear colour is
        // re-stated by the renderer before each of its own clears, so neither write can
        // desynchronise a cached state.
        glDisable(GL_SCISSOR_TEST);
        glClearColor(0, 0, 0, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    }
    // [R21] The host frame's GPU query opens HERE — the last statement of the first BeginEye
    // of the frame, so the in-flight and eye-slot waits above (CPU stalls, not GPU work) are
    // outside it. Self-guarded: a query is already open on the frame's later BeginEye calls.
    xr3_gpuq_begin();
}

// After both eyes: publish this frame's buffer pair WHEN ITS GPU WORK COMPLETES (shared-
// event listener), then advance the ring so the next engine frame writes another pair.
// The compositor consumes only published pairs — no cross-queue fence needed, and the
// engine's next frame can overlap the compositor's sampling of the previous one.
// Each scheduled completion counts against the in-flight bound (BeginEye eye 0 waits).
void VID_iOS_XR3_EndFrame(void) {
    if (!q2_xr3_mode) return;
    // [R20] The LAST eye's MSAA resolve — before the sync below, so the resolve is inside the
    // command buffer the publish fence waits on. A publish that raced its own resolve would
    // show the compositor a half-resolved eye, which is the R14 class of defect all over.
    xr3_ms_resolve();
    // [R21] Close the host frame's GPU query and drain whatever has completed — after the
    // resolve (which is this frame's GPU work and belongs inside the measurement) and before
    // the publish sync. Never a blocking result read; see xr3_gpuq_end.
    xr3_gpuq_end();
    V_SetStereoOffset(0);
    EGLDisplay dpy = eglGetCurrentDisplay();
    if (dpy == EGL_NO_DISPLAY) return;
    // [R14] THE PRE-SYNC BARRIER (`q2vrpubfence` 1 and 2). Eye 1's GL work is the last thing
    // submitted before the sync below, and nothing in this file has ever PROVED that ANGLE
    // encodes its signal after that work retires — only that the call order looks right. Mode
    // 1 asks ANGLE to make every prior command buffer scheduled first; mode 2 waits for them
    // to complete, which is the heavy hammer, costs the producer its pipelining and exists to
    // settle the question in one session. The cost is timed either way and reported as
    // `fence_us`, so "it did nothing" and "it did nothing measurable" cannot be confused.
    const int fenceMode = atomic_load(&s_pubFenceMode);
    if (fenceMode == 1 || fenceMode == 2) {
        uint64_t t0 = xr3_now_us();
        if (fenceMode == 1) { glFlush(); eglWaitUntilWorkScheduledANGLE(dpy); }
        else                { glFinish(); }
        uint64_t us = xr3_now_us() - t0;
        atomic_fetch_add(&s_fenceSamples, 1);
        atomic_fetch_add(&s_fenceUsTotal, us);
        uint64_t mx = atomic_load(&s_fenceUsMax);
        while (us > mx && !atomic_compare_exchange_weak(&s_fenceUsMax, &mx, us)) { }
    }
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
    // The block outlives this call and used to capture the ring's pointers RAW. It now takes
    // its own ref on each (D-VR-R3.1): the ring can be replaced under a scheduled block — a
    // live Render Quality change does exactly that — and a borrowed pointer published after
    // its texture was freed is a use-after-free the compositor then samples. Each ref is
    // handed to the matching publish slot below, which owns it until it is superseded.
    void *p0 = xr3_hold(s_buf[0][s_ping].mtl), *p1 = xr3_hold(s_buf[1][s_ping].mtl);
    void *d0 = xr3_hold(s_buf[0][s_ping].depthMtl), *d1 = xr3_hold(s_buf[1][s_ping].depthMtl);
    void *u0 = s_uiArmed ? xr3_hold(s_ui[s_ping].mtl) : NULL;
    // The epoch this frame was SCHEDULED under (D-VR-R4). If it has moved by the time the block
    // fires, something tore down the generation these five textures belong to and the publish
    // must not land.
    const int epoch = atomic_load(&s_pubEpoch);
    // [R8] The pose id these five textures were rendered with, captured on the ENGINE
    // thread and carried into the block so it lands with the pixels, not with the clock.
    const uint64_t poseId = atomic_load(&s_framePoseId);
    // [R9] The ring slot these five textures live in, captured beside them so it can be
    // published inside the seqlock with them.
    const int slot = s_ping;
    // [R14] THE DEPTH-DECODE CONSTANTS, captured HERE — on the engine thread, at the end of
    // the frame that rendered these pixels — instead of being read live by the compositor
    // three frames later. `zfar_used` is gl_static.world.size * 2 and changes on EVERY map
    // load; a pair presented across that change had its entire depth buffer decoded against
    // the wrong far plane, which reprojects the whole world at the wrong distance for a frame
    // or two. `nearC` comes from the pose this frame was rendered with, per eye, for the same
    // reason R10 made it per-eye in the first place.
    q2_vr_depthconst_t dc;
    dc.znear = q2vr.znear > 0 ? q2vr.znear : 2.0f;
    dc.zfar  = q2vr.zfar_used > 0 ? q2vr.zfar_used : 4096.0f;
    dc.worldScale = Q2_VR_WorldScale();
    dc.nearC[0] = dc.nearC[1] = 0.0f;
    {
        const q2_vr_pose_t *rp = (const q2_vr_pose_t *)Q2_VR_AcquiredPose();
        if (rp) for (int e = 0; e < 2; e++) {
            float zn = rp->eye[e].znear_m > 0.001f ? rp->eye[e].znear_m : rp->znear_m;
            dc.nearC[e] = (zn > 0.001f && zn < 5.0f) ? zn : 0.0f;
        }
    }
    // [R14] The shared event this pair is signalled on, held for the compositor to WAIT on
    // inside its own command buffer. `event` is ARC-owned here; the publish slot takes its own
    // +1 exactly as the five textures do, and the refuse path retires it with them.
    void *fenceEvt = (void *)CFBridgingRetain(event);
    const uint64_t fenceVal = value;
    atomic_fetch_add(&s_inFlight, 1);
    [event notifyListener:s_listener atValue:value
                    block:^(id<MTLSharedEvent> e, uint64_t v) {
        (void)e; (void)v;   // block retains the event until it fires
        if (atomic_load(&s_pubEpoch) != epoch) {
            // REFUSED. The block owns one ref on each of these, so it releases them itself —
            // through xr3_retire, not CFRelease, because the compositor may have fetched one of
            // them out of a slot before the clear and still be sampling it. framesRendered is
            // NOT advanced: nothing was published, and a counter that says otherwise is how a
            // suite comes to believe a torn-down generation is on screen. The decrement still
            // happens, or the in-flight gate leaks upward and wedges the producer.
            xr3_retire(p0); xr3_retire(p1);
            xr3_retire(d0); xr3_retire(d1);
            xr3_retire(u0);
            xr3_retire(fenceEvt);
            atomic_fetch_add(&s_pubRefused, 1);
            int c = atomic_load(&s_inFlight);
            while (c > 0 && !atomic_compare_exchange_weak(&s_inFlight, &c, c - 1)) { }
            return;
        }
        // Depth is published with colour, and — R7a — ATOMICALLY WITH RESPECT TO THE READER
        // as well as the writer. A compositor that samples a colour image against another
        // frame's depth reprojects the world against geometry that is not in it, and the
        // artefact looks like a tracking bug rather than a pairing bug, which is how it
        // survives a round. Odd while the set is being replaced; even when it is whole.
        atomic_fetch_add(&s_pubSeq, 1);
        xr3_pub_set(&s_pub[0], p0, true);
        xr3_pub_set(&s_pub[1], p1, true);
        xr3_pub_set(&s_pubDepth[0], d0, true);
        xr3_pub_set(&s_pubDepth[1], d1, true);
        xr3_pub_set(&s_pubUI, u0, true);
        atomic_store(&s_pubPoseId, poseId);   // [R8] inside the seqlock, with the pixels
        atomic_store(&s_pubSlot, slot);       // [R9] ditto: the slot the consumer must hold
        s_pubDepthConst = dc;                 // [R14] and the constants that decode its depth
        // [R14] The fence, published from INSIDE the block that the event firing armed — so
        // by the time the compositor can read this event/value pair the value is already
        // signalled, and the wait it encodes can never be a wait for something that will not
        // happen. That is the whole deadlock argument, and it lives here beside the store.
        xr3_pub_set(&s_pubFenceEvent, fenceEvt, true);
        atomic_store(&s_pubFenceValue, fenceVal);
        atomic_fetch_add(&s_pubSerial, 1u);
        atomic_fetch_add(&s_pubSeq, 1);
        atomic_fetch_add(&s_framesRendered, 1);
        // Clamped, never a bare fetch_sub: BeginEye's self-heal and SetMode both RESET this
        // counter, and a block that fires afterwards would otherwise push it negative — which
        // reads as "nothing in flight" forever and disables both the gate and the drain.
        int cur = atomic_load(&s_inFlight);
        while (cur > 0 && !atomic_compare_exchange_weak(&s_inFlight, &cur, cur - 1)) { }
    }];
    s_ping = (s_ping + 1) % s_ringActive;   // [R19] the ACTIVE depth, which the budget may shrink
}

#endif // Q2_XR_UI
