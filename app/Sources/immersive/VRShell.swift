// VRShell.swift — the VR compositor loop: full immersion, per-eye world frames, real depth.
//
// This is a SECOND compositor loop beside Q2PanelRenderer, not a mode inside it. The panel
// is a world-locked screen the compositor may sample whenever it likes; VR is pose-locked
// and may not. The two contracts differ in every load-bearing detail — free-run vs
// rendezvous, mixed vs full immersion, synthetic far depth vs converted scene depth,
// passthrough clear vs opaque clear — and a single loop carrying both would be a loop whose
// every line has an "if vr" in it.
//
// What the simulator can and cannot prove here. It can prove the plumbing: that a pair is
// published, that the engine renders against the pose it was given, that the eye images
// respond to an injected pose, that arbitration picks the right surface and says why. It
// CANNOT prove reprojection, because there is none — which is why the sky depth floor below
// has a fault injector rather than a simulator assertion.
import CompositorServices
import SwiftUI
import Metal
import ARKit
import QuartzCore
import simd

struct Q2VRConfig: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        let layouts = capabilities.supportedLayouts(options: [])
        // Dedicated layout gives per-eye textures AND per-eye rate maps. Layered plus
        // per-slice passes plus foveation rasterizes every pass with layer 0's rate map,
        // which shows up as a right-eye fisheye. Do NOT touch maxRenderQuality.
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
    }
}

struct Q2VRContent: CompositorContent {
    var body: some CompositorContent {
        CompositorLayer(configuration: Q2VRConfig()) { @MainActor layerRenderer in
            let r = Q2VRRenderer(layerRenderer)
            let t = Thread { r.run() }
            t.name = "q2-vr"; t.stackSize = 2 << 20
            t.start()
        }
    }
}

final class Q2VRRenderer {
    private static let currentLock = NSLock()
    private static var _current: Q2VRRenderer?
    static var current: Q2VRRenderer? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); _current = newValue; currentLock.unlock() }
    }
    private let lock = NSLock()
    private var _stop = false
    private var _running = false
    var stopRequested: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stop }
        set { lock.lock(); _stop = newValue; lock.unlock() }
    }
    var running: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _running }
        set { lock.lock(); _running = newValue; lock.unlock() }
    }

    let layer: LayerRenderer
    let device: MTLDevice
    let queue: MTLCommandQueue
    // [R23] THE TRACKING SESSION IS PER ENTRY, AND IT IS NOT FIRE-AND-FORGET.
    //
    // Reported on 1.0.11.26: "sometimes when entering VR mode, it'll be a black screen but with
    // audio. I have to exit VR then re-enter, then it's fine." Every entry builds a NEW
    // Q2VRRenderer — and therefore a new ARKitSession and a new WorldTrackingProvider — while
    // the PREVIOUS entry's session was never stopped: it lived until its renderer happened to
    // be released, which is after the next space has already opened. Two world-tracking
    // providers overlapping is a documented way for the second `run` to be refused, and the
    // refusal was swallowed whole by `try?`. A provider that never runs makes
    // `queryDeviceAnchor` return nil for the WHOLE session, so `drawable.deviceAnchor` is
    // never set — and a frame the system cannot reproject is a frame it does not show. Black,
    // with the engine and the mixer running perfectly behind it, cured by an exit and a
    // re-entry, which is exactly the report.
    //
    // So: the session is stopped on the way out (deterministically, not at dealloc), the run
    // error is LOGGED instead of dropped, and the state is fed to the entry watch every frame
    // so `VRENTRY` can say `no_anchor` instead of leaving the next report to guesswork.
    private let trackLock = NSLock()
    private var _arSession = ARKitSession()
    private var _worldTracking = WorldTrackingProvider()
    private var arSession: ARKitSession { trackLock.lock(); defer { trackLock.unlock() }; return _arSession }
    private var worldTracking: WorldTrackingProvider { trackLock.lock(); defer { trackLock.unlock() }; return _worldTracking }

    // Start (or restart) world tracking on a session and provider of its own. A provider that
    // has been stopped can never run again, so a restart is a new pair — and the old session
    // is stopped BEFORE the new one runs, which is the ordering the overlap needed.
    private func startTracking(_ why: String) {
        let s = ARKitSession()
        let p = WorldTrackingProvider()
        trackLock.lock()
        let old: ARKitSession? = (why == "entry") ? nil : _arSession
        _arSession = s; _worldTracking = p
        trackLock.unlock()
        old?.stop()
        Task {
            do {
                try await s.run([p])
                Q2_XR3_Log("VRTRACK world tracking running (\(why))")
            } catch {
                Q2_XR3_Log("VRTRACK world tracking run FAILED (\(why)) \(error)")
                Q2_VR_NoteArkit(-1, 1)
            }
        }
    }

    private func stopTracking() {
        trackLock.lock(); let s = _arSession; trackLock.unlock()
        s.stop()
        Q2_XR3_Log("VRTRACK world tracking stopped (VR exit)")
    }

    // Provider state as an ordinal the C side can print: 0 initialized, 1 running, 2 paused,
    // 3 stopped, -1 anything a future SDK adds.
    private func trackingStateOrdinal() -> Int32 {
        switch worldTracking.state {
        case .initialized: return 0
        case .running:     return 1
        case .paused:      return 2
        case .stopped:     return 3
        @unknown default:  return -1
        }
    }

    // [R23] THE SELF-HEAL, and the two things it is not allowed to do.
    // It fires only when the entry is in a state that produces a black picture and has been in
    // it for a full second of compositor frames — never during a VRRESIZE settle (a quality
    // change replaces the whole eye ring, and the shell legitimately holds nothing until the
    // first pair at the new size lands, so the eye generation must have been STABLE), and
    // never while the app is backgrounded (the engine thread is winding down and re-running
    // ARKit there is a request against a scene that is gone). Bounded at three attempts per
    // session: a heal that has not taken by the third is a different bug and hammering it
    // would only bury the VRENTRY line that says so.
    private var healAttempts = 0
    private var lastHealFrame = 0
    private var anchorEver = false
    private var adoptEver = false
    private var genStableSince = 0
    private var lastSeenGen: Int32 = -1

    private func maybeHeal(gen: Int32, haveAnchor: Bool, adopted: Bool) {
        if haveAnchor { anchorEver = true }
        if adopted { adoptEver = true }
        if gen != lastSeenGen { lastSeenGen = gen; genStableSince = frames }
        guard healAttempts < 3, Q2_VR_AppBackgrounded() == 0 else { return }
        guard frames - genStableSince >= 60, frames >= 60 else { return }
        guard frames - lastHealFrame >= 120 || lastHealFrame == 0 else { return }
        if !anchorEver {
            // Nothing to reproject against: re-run world tracking on a fresh session.
            healAttempts += 1; lastHealFrame = frames
            Q2_XR3_Log("VRENTRY heal=arkit frames=\(frames) attempt=\(healAttempts) - no device anchor since entry")
            Q2_VR_NoteEntryHeal("arkit")
            startTracking("heal")
        } else if !adoptEver && VID_iOS_XR3_FramesRendered() > 0 {
            // The engine is publishing and this side has never had a pair in hand: drop
            // everything the shell caches ABOUT the pair (the private copies, their serials,
            // the pipelines) so the next frame rebuilds from whatever is published now. This
            // is the subset of "exit and re-enter" that touches only the consumer.
            healAttempts += 1; lastHealFrame = frames
            Q2_XR3_Log("VRENTRY heal=adopt frames=\(frames) attempt=\(healAttempts) - pairs published, none adopted")
            Q2_VR_NoteEntryHeal("adopt")
            lastCopyGen = -1
            privColor = []; privDepth = []
            haveColorCopy = false; haveDepthCopy = false
            lastColorSerial = 0; lastDepthSerial = 0
            sharpTex = []; lastSharpGen = -1; lastSharpFrame = -1
            eyePipeline = nil; panelPipeline = nil; uiPipeline = nil
        }
    }

    private var eyePipeline: MTLRenderPipelineState?
    private var panelPipeline: MTLRenderPipelineState?
    private var uiPipeline: MTLRenderPipelineState?
    private var casPipeline: MTLComputePipelineState?
    private var depthState: MTLDepthStencilState?
    // Sharpened private copies of the published eye pair. Owned by THIS queue, so the copy,
    // the sharpen and the sample all stay coherent without a cross-queue fence, exactly like
    // the 3D panel's copyTex. Rebuilt whenever the eye size changes.
    private var sharpTex: [MTLTexture] = []
    private var lastSharpGen: Int32 = -1
    private var lastSharpFrame: Int32 = -1
    // [R9 item 1] COMPOSITOR-OWNED COPIES of the published pair. Both donors do exactly this
    // (quake3e `q3e_vr_ensure_copy`, vkQuake `VKQVR.m`): the consumer never samples the
    // producer's own images, it blits them into private textures it owns and samples those.
    // Colour was only ever accidentally safe here — CAS copied it, and with `vr_sharpen 0`
    // even that went away — while DEPTH was sampled raw out of the engine's ring on every
    // frame, which is what tore on head turns. The copies are refreshed once per NEW publish
    // (keyed on the publish serial, not on a frame count read outside the snapshot) and the
    // ring slot is held for the life of the command buffer that does the copy.
    private var privColor: [MTLTexture] = []
    private var privDepth: [MTLTexture] = []
    private var haveColorCopy = false
    private var haveDepthCopy = false
    private var lastColorSerial: UInt32 = 0
    private var lastDepthSerial: UInt32 = 0
    private var lastCopyGen: Int32 = -1

    private var frames = 0
    private var contractDumped = false
    private var baseFromWorld: simd_float4x4?        // play-space origin, captured at entry
    // [R17] THE ENTRY SETTLE. Reported: "sometimes when I exit and re-enter VR my height is all
    // wrong; Re-calibrate Height does not fix it, Recenter View does." The base is captured on
    // the FIRST anchor the space delivers, and on a re-entry that anchor can be pre-convergence
    // (untracked, or a stale origin): a base whose Y is wrong puts the head a metre off the
    // floor and only a recentre — which re-captures the base — repairs it. So the first capture
    // is provisional: once the anchor reports tracked and has been still for a quarter second
    // the base is re-captured through the SAME recentre path a Recenter View press uses (the
    // yaw about to be zeroed is absorbed into the body yaw, so nothing swings). Once per entry.
    private var baseCapturedAt: Double = 0
    private var baseSettled = false
    private var firstAnchorAt: Double = 0
    private var stillSince: Double = 0
    private var lastAnchorPos = SIMD3<Float>(repeating: .nan)
    private var lastAnchorYaw: Float = 0
    private var lastGoodAnchor: DeviceAnchor?        // the anchor the last presented pair used
    // [R8] THE POSE RING. `Q2_VR_WaitRendered` closes on the CPU, but the eye textures for
    // that frame are only published one to two GPU frames later — so the pair this
    // compositor frame PRESENTS was rendered against an OLDER head anchor than the one it
    // just published. Submitting the newer anchor makes the compositor reproject old pixels
    // against a new pose: no error standing still, error proportional to angular velocity
    // while turning, identical in both eyes. That is exactly the reported defect.
    // Indexed by `id % kPoseRing` so a lookup is O(1), with no search and no allocation per
    // frame; the stored id is re-checked on read, so a wrapped slot misses rather than
    // handing back some other frame's anchor. On device the publish latency is one to two
    // frames, but the shell publishes an id per COMPOSITOR frame while the engine renders
    // slower than that, so the gap is measured in compositor frames and spikes whenever the
    // engine does — a simulator run reaches six. 32 is a few hundred bytes and takes the
    // ring out of the argument entirely: an older anchor is not a worse one, it is the
    // correct one for those pixels.
    // [R9] 128, not 32. The bound on this ring is the PUBLISH LAG in rendezvous ids, and on
    // the simulator a single slow engine frame (a map load, a full-resolution readback) spikes
    // that to tens of frames — past 32 the anchor for the presented pair is gone and the frame
    // falls back, which is the very state R8-3 asserts against. Four times the margin costs a
    // few kilobytes.
    private static let kPoseRing = 128
    // [R10 item 1] THE RING NOW CARRIES THE FRUSTUM TOO. The composite assumes the frustum the
    // engine RENDERED frame N with is the frustum the drawable PRESENTS frame N+lag against,
    // and nothing in the code compares the two. Storing what `makeEye()` already computed —
    // this eye's tangents and this eye's transform column — makes the comparison possible, and
    // the VRFRUSTUM line below is the measurement that decides whether the assumption holds on
    // a device (on the simulator it cannot fail: views.count == 1, so both eyes get one static
    // set of tangents). Two SIMD4s and two SIMD3s per slot: a few kilobytes for the ring.
    private var poseRing = [(id: UInt64, anchor: DeviceAnchor?,
                             tan: (SIMD4<Float>, SIMD4<Float>),
                             pos: (SIMD3<Float>, SIMD3<Float>))](
        repeating: (0, nil, (.zero, .zero), (.zero, .zero)), count: Q2VRRenderer.kPoseRing)
    private var staleAnchorFrames = 0                // world frames with no matching anchor
    private var lastAnchorLogTime: Double = 0

    // ---- [R10 item 3] THE VR STATS WINDOW -------------------------------------------------
    // These are read in the headset, where there is no console and no log. Everything is
    // accumulated over one second and reset, so the block is a RATE and not a lifetime total —
    // a lifetime average cannot tell a run that started badly from one that is going badly now.
    // Every accumulation except the frame count is gated on the row being ON.
    // [R21] The R10 stats-overlay accumulators are gone with the row (the FPS Counter row is
    // what a player wanted from them). `statsPrevSerial` stays: the repeat-run counter on the
    // once-a-second VRCLOCK line is built from it and has nothing to do with the overlay.
    private var statsPrevSerial: UInt32 = 0
    private var lastPanelDegrees: Float = 0          // last logged Menu Panel Size

    // [R13] THE WHEEL PULL — depth for a 2D wheel (Q-VR12). Reported: "can we add depth to the
    // wheels?" The wheel is a region of the ONE head-locked UI quad, so per-element depth would
    // mean a second composited surface. But `quadModel` derives the quad's half-width FROM its
    // distance, so easing the WHOLE quad closer while a wheel is open changes the vergence and
    // the reprojection depth (`uiParams` below is znear/dist) and leaves the angular size
    // pixel-identical: the HUD does not appear to grow, it appears to come forward. Zero draws,
    // no new texture, no new pass. Eased rather than snapped because a stepped vergence change
    // is uncomfortable; the coefficient is per compositor frame, ~150 ms at 90 Hz.
    private var wheelPullEase: Float = 1.0

    // [R11] VRCLOCK — WHAT THE LAYER'S CADENCE ACTUALLY IS, and how much of it is our wait.
    // The device reports `comphz=60.0` on a headset whose display is nominally 90 Hz, and
    // PACENOW measures that at the PUBLISH statement — which is downstream of
    // `Q2_VR_WaitRendered`, so a 14 ms wait that always expires would produce exactly that
    // number and look like a display rate. These two sets separate the question: the layer's
    // own frame period, taken from consecutive `presentationTime` deltas (nothing of ours is
    // in that number), and the wait's own mean/max/timeout count beside it.
    private var clockPrevPresent: Double = 0
    private var clockPeriods: [Double] = []          // seconds, one per compositor frame
    private var clockWaits: [Double] = []            // seconds spent inside WaitRendered
    private var clockWaitMax: Double = 0
    private var clockTimeouts = 0                    // waits that returned !fresh (budget hit)
    // [R14] THE TWO EXPLANATION COUNTERS the flicker diagnosis asked for, both in the
    // once-a-second budget and both pure counters — nothing logs per frame.
    // `repmax` is the LONGEST RUN of consecutive compositor frames that re-presented one
    // published pair. `repeat%` already says how often it happens; a run says whether the
    // headset is reprojecting the same pixels four deep, which is what a load-time stall
    // looks like from here and what a steady 2:1 producer/consumer ratio does not.
    // `late` is how many of our presenting command buffers finished AFTER the drawable's own
    // presentation time — i.e. we missed the layer's deadline and the compositor showed the
    // previous frame. It is the answer to VRCLOCK's unexplained 120/60 flip.
    private var repeatRun = 0
    private var repeatRunMax = 0
    private let lateBox = LateFrameBox()
    private var panelAnchor: simd_float4x4?          // captured on the transition INTO panel
    private var wasWorld = true

    // Per-frame shader constants. Matches the `EyeParams` struct in the Metal source below;
    // a mismatch here is silent, so the two are written next to each other on purpose.
    private struct EyeParams {
        var znear: Float = 2
        var zfar: Float = 4096
        var worldScale: Float = 34
        var nearC: Float = 0.1
        var depthFloor: Float = 1.0 / 8192.0
        var hasDepth: Int32 = 0
        var pad0: Int32 = 0
        var pad1: Int32 = 0
    }

    init(_ layer: LayerRenderer) {
        self.layer = layer
        self.device = layer.device
        self.queue = device.makeCommandQueue()!
        startTracking("entry")
    }

    // MARK: - pipelines

    private func buildPipelines(color: MTLPixelFormat, depth: MTLPixelFormat) {
        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct EyeParams {
            float znear;        // engine near plane, WORLD UNITS (q2vr.znear)
            float zfar;         // engine far plane, WORLD UNITS (gl_static.world.size * 2)
            float worldScale;   // units per metre
            float nearC;        // the compositor's own near plane, METRES
            float depthFloor;   // never emit a depth the compositor reads as "nothing here"
            int   hasDepth;
            int   pad0;
            int   pad1;
        };

        struct VOut { float4 pos [[position]]; float2 uv; };

        // Fullscreen triangle. The pass rasterizes into the view's LOGICAL viewport with
        // that view's rate map attached; the engine rendered at the PHYSICAL texture size.
        // The rate map is what bridges the two, which is why neither number is hardcoded.
        vertex VOut q2eyevtx(uint vid [[vertex_id]]) {
            const float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            VOut o;
            o.pos = float4(p[vid], 0, 1);
            // GL renders bottom-up: v = 0 is the image bottom.
            o.uv = float2((p[vid].x + 1) * 0.5, (p[vid].y + 1) * 0.5);
            return o;
        }

        struct EyeOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };

        // THE CONVERSION. q2repro is forward-Z with a FINITE, per-map far plane; the
        // compositor is reverse-Z with an INFINITE one and a ~0.1 m near plane. Undo the
        // engine's projection to a real eye-space distance, take it to metres, then write
        // the compositor's reciprocal form.
        //
        // THE SKY. A surface at the far plane converts to a value indistinguishable from
        // the compositor's cleared "nothing was rendered here", and depth-based
        // reprojection turns that into BLACK. The donors lost five builds and four wrong
        // theories to it, the real mechanism was found by a person noticing that the sky
        // survived exactly where a panel had written real depth, and NO simulator can
        // reproduce it because there is no reprojection in one. Hence the floor — about
        // 800 m at a 0.1 m near plane — and `q2vrdepthfloor 0`, which restores the bug
        // exactly and is a one-command causality proof on glass.
        fragment EyeOut q2eyefrag(VOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  depth2d<float> dtex [[texture(1)]],
                                  constant EyeParams &P [[buffer(0)]]) {
            constexpr sampler cs(filter::linear, address::clamp_to_edge, max_anisotropy(16));
            constexpr sampler ds(filter::nearest, address::clamp_to_edge);
            EyeOut o;
            float4 c = tex.sample(cs, in.uv);
            o.color = float4(pow(max(c.rgb, float3(0.0)), 2.2), 1.0);   // display-encoded -> linear
            if (P.hasDepth == 0) {
                o.depth = P.nearC / 2.0;      // 2 m constant: honest fallback, and it SAYS so
                                              // in the pinned diagnosis line, so "depth is
                                              // working" can never be an assumption.
                return o;
            }
            float d = dtex.sample(ds, in.uv);
            float denom = max(P.zfar - d * (P.zfar - P.znear), 1e-6);
            float zUnits = (P.zfar * P.znear) / denom;
            float zM = max(zUnits / max(P.worldScale, 1e-3), 1e-4);
            o.depth = clamp(P.nearC / zM, P.depthFloor, 1.0);
            return o;
        }

        // Panel fallback inside the VR space: menus, console, loading, demos, cinematics.
        //
        // `uvRect` (R3) is the sub-rect of the source texture this quad shows: xy = scale,
        // zw = bias. A VR eye target is nearly square and the engine composes its whole 2D
        // stream for `r_config`, which is why the menus looked square on the first headset
        // build; the engine now draws them into a 16:9 sub-rect of the SAME texture (no
        // re-allocation, see VID_iOS_XR3_SetPanelShape) and this samples exactly that rect.
        // The UI quad passes (1,1,0,0) and gets the whole texture, as it always did.
        struct POut { float4 pos [[position]]; float2 uv; };
        vertex POut q2vrpanelvtx(uint vid [[vertex_id]], constant float4x4 &mvp [[buffer(0)]],
                                 constant float4 &uvRect [[buffer(1)]]) {
            const float2 p[4]  = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            const float2 uv[4] = { float2(0,0),   float2(1,0),  float2(0,1),  float2(1,1) };
            POut o; o.pos = mvp * float4(p[vid], 0, 1);
            o.uv = uv[vid] * uvRect.xy + uvRect.zw;
            return o;
        }
        fragment float4 q2vrpanelfrag(POut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge,
                                max_anisotropy(16));
            float4 c = tex.sample(s, in.uv);
            return float4(pow(max(c.rgb, float3(0.0)), 2.2), 1.0);
        }

        // THE UI QUAD (charter D6). The engine's whole 2D stream has been drawn ONCE into its
        // own texture, cleared to transparent black, so this composites it over the world at a
        // real distance with REAL depth — not pasted onto the eye image where it would sit on
        // the horizon and reproject like scenery a kilometre away.
        struct UIOut { float4 color [[color(0)]]; float depth [[depth(any)]]; };
        struct UIParams { float depthValue; float pad0; float pad1; float pad2; };
        fragment UIOut q2vruifrag(POut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]],
                                  constant UIParams &P [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge, max_anisotropy(16));
            float4 c = tex.sample(s, in.uv);
            // DISCARD, not a zero-alpha write. The depth state writes unconditionally (the
            // compositor rejects frames it cannot reproject), so a transparent pixel that
            // reached the depth test would stamp the quad's distance over the world behind
            // it and punch a HUD-shaped hole in the reprojection.
            if (c.a < 0.02) discard_fragment();
            UIOut o;
            o.color = float4(pow(max(c.rgb, float3(0.0)), 2.2) * c.a, c.a);
            o.depth = P.depthValue;
            return o;
        }

        // CONTRAST-ADAPTIVE SHARPENING for the VR eye images (R3 — "resolution seems kinda
        // low"). The eye image takes two resamples before it reaches an eyeball: the composite
        // draws a fullscreen triangle into the view's LOGICAL viewport (the foveation-expanded
        // raster area) sampling the engine texture bilinearly, and the system's rate map then
        // resolves that back to the physical texture. Two bilinear steps are two low-pass
        // filters, and the engine renders with MSAA off in VR (a multisampled depth buffer is
        // not a valid snapshot for reprojection), so there is no other edge reconstruction in
        // the chain at all. vkQuake ships Sharpen at 50% in VR for exactly this; the 3D panel
        // in this app already got the same treatment as its de-blur fix.
        //
        // Identical kernel to the panel's q2cas, deliberately: one sharpener with one set of
        // constants means a taste judgement made in one mode transfers to the other.
        kernel void q2vrcas(texture2d<float, access::read> srcT [[texture(0)]],
                            texture2d<float, access::write> dstT [[texture(1)]],
                            constant float &strength [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            uint W = dstT.get_width(), H = dstT.get_height();
            if (gid.x >= W || gid.y >= H) return;
            float3 c = srcT.read(gid).rgb;
            float3 a = srcT.read(uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0)).rgb;
            float3 b = srcT.read(uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y)).rgb;
            float3 d = srcT.read(uint2(min(gid.x + 1, W - 1), gid.y)).rgb;
            float3 e = srcT.read(uint2(gid.x, min(gid.y + 1, H - 1))).rgb;
            float3 mn = min(min(min(a, b), min(d, e)), c);
            float3 mx = max(max(max(a, b), max(d, e)), c);
            float3 amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, float3(0.001))));
            float peak = mix(8.0, 5.0, saturate(strength));
            float3 w = -amp / peak;
            float3 o = (c + (a + b + d + e) * w) / (1.0 + 4.0 * w);
            dstT.write(float4(saturate(o), 1.0), gid);
        }
        """
        do {
            let lib = try device.makeLibrary(source: src, options: nil)
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "q2eyevtx")
            pd.fragmentFunction = lib.makeFunction(name: "q2eyefrag")
            pd.colorAttachments[0].pixelFormat = color
            pd.depthAttachmentPixelFormat = depth
            pd.inputPrimitiveTopology = .triangle
            eyePipeline = try device.makeRenderPipelineState(descriptor: pd)

            let qd = MTLRenderPipelineDescriptor()
            qd.vertexFunction = lib.makeFunction(name: "q2vrpanelvtx")
            qd.fragmentFunction = lib.makeFunction(name: "q2vrpanelfrag")
            qd.colorAttachments[0].pixelFormat = color
            qd.depthAttachmentPixelFormat = depth
            qd.inputPrimitiveTopology = .triangle
            panelPipeline = try device.makeRenderPipelineState(descriptor: qd)

            let ud = MTLRenderPipelineDescriptor()
            ud.vertexFunction = lib.makeFunction(name: "q2vrpanelvtx")
            ud.fragmentFunction = lib.makeFunction(name: "q2vruifrag")
            ud.colorAttachments[0].pixelFormat = color
            // Premultiplied: the fragment multiplies by alpha, so the blend is one /
            // one-minus-source-alpha and a linear-space HUD edge does not fringe.
            ud.colorAttachments[0].isBlendingEnabled = true
            ud.colorAttachments[0].rgbBlendOperation = .add
            ud.colorAttachments[0].alphaBlendOperation = .add
            ud.colorAttachments[0].sourceRGBBlendFactor = .one
            ud.colorAttachments[0].sourceAlphaBlendFactor = .one
            ud.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            ud.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            ud.depthAttachmentPixelFormat = depth
            ud.inputPrimitiveTopology = .triangle
            uiPipeline = try device.makeRenderPipelineState(descriptor: ud)

            let dsd = MTLDepthStencilDescriptor()
            // The compositor REJECTS frames it cannot reproject, so depth is always written;
            // the fragment decides the value, the depth state never gates it.
            dsd.depthCompareFunction = .always
            dsd.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: dsd)
            if let f = lib.makeFunction(name: "q2vrcas") {
                casPipeline = try? device.makeComputePipelineState(function: f)
            }
        } catch {
            Q2_XR3_Log("VR pipeline build FAILED \(error)")
        }
    }

    // MARK: - loop

    func run() {
        running = true
        Q2VRRenderer.current = self
        // [R23] The tracking session is stopped HERE and not at dealloc: the next entry builds
        // its own, and two live world-tracking providers is how one of them stops answering.
        defer { running = false; Q2VRRenderer.current = nil; stopTracking() }
        var pausedTicks = 0
        while !stopRequested {
            switch layer.state {
            case .paused:
                // waitUntilRunning blocks with no timeout and no way to observe the stop
                // flag from inside it, so a stop landing on a paused layer parks this
                // thread while the exit handshake expires and the space is dismissed out
                // from under it. Poll: the BLOCKING is bounded, the pause is not (a headset
                // off the head is legitimately paused).
                Thread.sleep(forTimeInterval: 0.01)
                pausedTicks += 1
                if pausedTicks == 500 { Q2_XR3_Log("vr layer paused >5s (still waiting)") }
            case .running:
                pausedTicks = 0
                autoreleasepool { frame() }
            case .invalidated:
                // The Digital Crown is not an exit we control. Treat "the system took the
                // space away" as a first-class path: reconcile the mode so the engine comes
                // back to the window, and belt-and-brace the two things that must happen
                // even when the state was already reconciled and no transition fires.
                DispatchQueue.main.async {
                    if Q2AppModel.shared.mode == .vr {
                        Q2AppModel.shared.mode = .flat
                    } else {
                        Q2_iOS_AutoPause()
                        Q2_iOS_WriteConfigSync()
                    }
                }
                return
            @unknown default: return
            }
        }
    }

    // MARK: - pose

    // ARKit tracking space is metres, y-up, right-handed, -z forward. Quake is z-up,
    // units, with yaw increasing to the LEFT and pitch increasing DOWNWARD. The pose is
    // published in head-local terms (forward/right/up and three Euler angles) so the
    // engine can compose it with the game's own view basis without either side needing a
    // matrix convention from the other.
    // Position plus yaw, inverted. Built by hand rather than by zeroing matrix elements:
    // re-orthonormalising a pitched basis by hand is how a port ends up with a base that is
    // ALMOST a rotation, and an almost-rotation scales the world by a fraction of a percent
    // per recentre.
    static func yawOnlyBaseInverse(_ a: simd_float4x4) -> simd_float4x4 {
        let f = -SIMD3<Float>(a.columns.2.x, a.columns.2.y, a.columns.2.z)
        // Levelled forward. A head looking straight up or down has no yaw to speak of; keep
        // the previous frame's rather than snapping to an arbitrary one.
        var flat = SIMD3<Float>(f.x, 0, f.z)
        if simd_length(flat) < 1e-4 { flat = SIMD3<Float>(0, 0, -1) }
        flat = simd_normalize(flat)
        let right = SIMD3<Float>(-flat.z, 0, flat.x)      // 90 degrees CW about +Y
        let up = SIMD3<Float>(0, 1, 0)
        let p = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right, 0)
        m.columns.1 = SIMD4<Float>(up, 0)
        m.columns.2 = SIMD4<Float>(-flat, 0)
        m.columns.3 = SIMD4<Float>(p, 1)
        return m.inverse
    }

    private func poseAngles(_ m: simd_float4x4) -> (yaw: Float, pitch: Float, roll: Float) {
        let r = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let u = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let f = -SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let deg = Float(180.0 / Double.pi)
        let yaw = atan2(-f.x, -f.z) * deg
        let pitch = -asin(max(-1, min(1, f.y))) * deg      // Quake pitch is positive DOWN
        let roll = -atan2(r.y, max(u.y, 1e-4)) * deg
        return (yaw, pitch, roll)
    }

    // Recover the four edge tangents from the compositor's own projection rather than
    // reading view.tangents. Two reasons: the projection is the matrix the compositor will
    // actually reproject against (asking a second source for the same fact is how a port
    // ends up hiding a wrong matrix behind a second wrong number), and the accessor's
    // availability differs by immersion style.
    private func tangents(_ p: simd_float4x4) -> (l: Float, r: Float, u: Float, d: Float) {
        let p00 = p.columns.0.x, p20 = p.columns.2.x
        let p11 = p.columns.1.y, p21 = p.columns.2.y
        let sumH = p00 != 0 ? 2 / p00 : 2.0            // l + r
        let difH = p20 * sumH                          // r - l
        let sumV = p11 != 0 ? 2 / p11 : 2.0            // u + d
        let difV = p21 * sumV                          // u - d
        return (l: (sumH - difH) * 0.5, r: (sumH + difH) * 0.5,
                u: (sumV + difV) * 0.5, d: (sumV - difV) * 0.5)
    }

    // [R9 item 1] The compositor's own colour and depth textures, matched to whatever the
    // engine last published. Re-created when the eye generation bumps (a Render Quality
    // change replaces the whole ring) or when a size or pixel format no longer matches, and
    // the "have a copy" flags drop with them so nothing samples uninitialised private memory.
    private func ensurePrivateCopies(gen: Int32, color: MTLTexture?, depth: MTLTexture?) {
        func matches(_ a: [MTLTexture], _ src: MTLTexture?) -> Bool {
            guard let src else { return a.isEmpty }
            return a.count == 2 && a[0].width == src.width && a[0].height == src.height
                && a[0].pixelFormat == src.pixelFormat
        }
        if gen != lastCopyGen {
            lastCopyGen = gen
            privColor = []; privDepth = []
            haveColorCopy = false; haveDepthCopy = false
            lastColorSerial = 0; lastDepthSerial = 0
        }
        if let c = color, !matches(privColor, c) {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: c.pixelFormat, width: c.width, height: c.height, mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .private
            privColor = (0..<2).compactMap { _ in device.makeTexture(descriptor: td) }
            haveColorCopy = false
            lastColorSerial = 0
        }
        if let d = depth, !matches(privDepth, d) {
            let td = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: d.pixelFormat, width: d.width, height: d.height, mipmapped: false)
            td.usage = [.shaderRead]
            td.storageMode = .private
            privDepth = (0..<2).compactMap { _ in device.makeTexture(descriptor: td) }
            haveDepthCopy = false
            lastDepthSerial = 0
        }
        if depth == nil && !privDepth.isEmpty { haveDepthCopy = false }
    }

    private func frame() {
        guard let frame = layer.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }
        frame.startUpdate(); frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        // An empty queryDrawables INVALIDATES the frame (it happens while the space is
        // being dismissed): calling endSubmission on it aborts __BUG_IN_CLIENT__.
        guard let drawable = drawables.first else { return }
        // Pipelines from the FIRST drawable's actual (negotiated) formats, BEFORE anything
        // can take an early exit. A drawable that has been queried must be presented:
        // calling endSubmission on a queried-but-unpresented drawable aborts
        // __BUG_IN_CLIENT__ inside cp_frame_end_submission, which is how the first VR
        // launch died — a frame-1-only crash, invisible to every path that gets a second
        // frame.
        if eyePipeline == nil, let c0 = drawable.colorTextures.first, let d0 = drawable.depthTextures.first {
            buildPipelines(color: c0.pixelFormat, depth: d0.pixelFormat)
        }
        guard let eyePipeline, let panelPipeline, let depthState else {
            // [R23] COUNTED, not silent. A pipeline that never builds presents an empty
            // drawable forever — black, with the engine and the mixer running — and until the
            // entry watch it left no trace but one line at build time. `pipe=0` on the VRENTRY
            // line names it outright.
            frames += 1
            Q2_VR_NoteCompositorFrame(0, 0, VID_iOS_XR3_EyeGeneration(), 0)
            let cmd = queue.makeCommandBuffer()!
            drawable.encodePresent(commandBuffer: cmd)
            cmd.commit()
            frame.endSubmission()
            return
        }

        // Query the device anchor at PRESENTATION time, not trackable time. Apple's own
        // header says so; trackable time is for trackable anchors.
        let t = drawable.frameTiming.presentationTime.timeInterval
        let anchorObj = worldTracking.queryDeviceAnchor(atTimestamp: t)
        let anchor = anchorObj?.originFromAnchorTransform
        // THE ALIGNMENT BASE, and the one thing about it that must be right: it is YAW-ONLY.
        // A full `a.inverse` (which is what R1 captured, and what every first attempt
        // captures) folds the head's PITCH and ROLL into the play space, so a base taken
        // while the player happened to be looking down leaves the world permanently tilted
        // and there is no way for them to discover why. The head owns pitch and roll; the
        // base owns yaw and position, and nothing else.
        if let a = anchor {
            let tracked = anchorObj?.isTracked ?? true
            if firstAnchorAt == 0 { firstAnchorAt = t }
            if baseFromWorld == nil {
                // Provisional capture: the first TRACKED anchor, or — so a simulator whose
                // anchor never reports tracked still gets a base — any anchor after one second.
                if tracked || t - firstAnchorAt > 1.0 {
                    baseFromWorld = Q2VRRenderer.yawOnlyBaseInverse(a)
                    baseCapturedAt = t
                    baseSettled = false
                    stillSince = 0
                    Q2_XR3_Log(String(format: "VRBASE captured yawonly=1 y=%.3fm tracked=%d",
                                      a.columns.3.y, tracked ? 1 : 0))
                }
            } else if Q2_VR_ConsumeRecenterRequest() != 0 {
                // RECENTRE, in one place, doing both halves in the same breath: the yaw that
                // is about to be zeroed is handed to the body yaw, so the view does not swing
                // when the base moves under it. Two functions, one call site each.
                let rel = baseFromWorld! * a
                let absorbed = poseAngles(rel).yaw
                baseFromWorld = Q2VRRenderer.yawOnlyBaseInverse(a)
                Q2_VR_NoteRecenter(absorbed)
                baseSettled = true          // a manual recentre is the settle
            } else if !baseSettled {
                // The settle watch: tracked, and still (5 mm, 0.3 deg frame to frame) for a
                // quarter second, at least half a second after the provisional capture. Then
                // ONE automatic recentre. A window that never goes still expires after three
                // seconds so a player who walks straight off is not recentred mid-stride.
                let p = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
                let yaw = poseAngles(a).yaw
                var dyaw = abs(yaw - lastAnchorYaw)
                if dyaw > 180 { dyaw = 360 - dyaw }
                let still = tracked && !lastAnchorPos.x.isNaN
                    && simd_length(p - lastAnchorPos) < 0.005 && dyaw < 0.3
                lastAnchorPos = p
                lastAnchorYaw = yaw
                if !still { stillSince = 0 } else if stillSince == 0 { stillSince = t }
                if still, stillSince > 0, t - stillSince >= 0.25, t - baseCapturedAt >= 0.5 {
                    let rel = baseFromWorld! * a
                    let ang = poseAngles(rel)
                    let d = rel.columns.3
                    baseFromWorld = Q2VRRenderer.yawOnlyBaseInverse(a)
                    Q2_VR_NoteRecenter(ang.yaw)
                    baseSettled = true
                    Q2_XR3_Log(String(format:
                        "VRBASE settled auto-recenter after=%.2fs dpos=(%.3f,%.3f,%.3f)m dyaw=%.1fdeg y=%.3fm",
                        t - baseCapturedAt, d.x, d.y, d.z, ang.yaw, a.columns.3.y))
                } else if t - baseCapturedAt > 3.0 {
                    baseSettled = true
                    Q2_XR3_Log("VRBASE settle window expired (never still) - base as captured")
                }
            }
            // Standing height, sampled every frame; the C side captures ONCE and gates it.
            Q2_VR_NoteHeadHeight(a.columns.3.y)
        }

        // Two-phase entry, phase 2: the eye targets are sized from the view's PHYSICAL
        // colour texture, never from textureMap.viewport (the foveation-expanded logical
        // raster area — sizing from it asked a donor's engine for ten times the pixels it
        // needed) and never from the panel's 16:9 pixel-budget formula.
        let tmap0 = drawable.views[0].textureMap
        let texIdx0 = min(tmap0.textureIndex, drawable.colorTextures.count - 1)
        let phys = drawable.colorTextures[texIdx0]
        Q2_VR_ReportPhysicalSize(Int32(phys.width), Int32(phys.height))

        frames += 1
        if !contractDumped {
            contractDumped = true
            let vp = tmap0.viewport
            let dfmt = drawable.depthTextures.first?.pixelFormat.rawValue ?? 0
            // STRUCTURAL: diffed on every later dump. If any of this moves, every
            // assumption downstream is suspect and the diff is the alarm.
            let structural = "VRCONTRACT_STRUCTURAL phys=\(phys.width)x\(phys.height) " +
                "logical=\(Int(vp.width))x\(Int(vp.height)) colorfmt=\(phys.pixelFormat.rawValue) " +
                "depthfmt=\(dfmt) texs=\(drawable.colorTextures.count) views=\(drawable.views.count) " +
                "ratemaps=\(drawable.rasterizationRateMaps.count) " +
                "enginedepth=\(VID_iOS_XR3_VRDepthActive() != 0 ? "texture" : "none")"
            // VOLATILE: never diffed. These change every frame by design, and diffing them
            // turns the instrument into noise.
            let proj0 = drawable.computeProjection(convention: .rightUpBack, viewIndex: 0)
            let tg = tangents(proj0)
            let volatileLine = String(format:
                "VRCONTRACT_VOLATILE tanL=%.3f tanR=%.3f tanU=%.3f tanD=%.3f nearC=%.4fm anchor=%d",
                tg.l, tg.r, tg.u, tg.d, proj0.columns.3.z, anchor != nil ? 1 : 0)
            Q2_VR_DumpContract(structural, volatileLine)
        }

        // ---- publish the pose the engine must render with ------------------------------
        var pose = q2_vr_pose_t()
        pose.views = Int32(drawable.views.count)
        pose.valid = 0
        if let a = anchor, let base = baseFromWorld {
            let rel = base * a
            let p = rel.columns.3
            pose.headFwd = -p.z
            pose.headRight = p.x
            pose.headUp = p.y
            let ang = poseAngles(rel)
            pose.headYawDeg = ang.yaw
            pose.headPitchDeg = ang.pitch
            pose.headRollDeg = ang.roll
            pose.valid = 1
        }
        var nearC: Float = 0.1
        // [R10 item 1] What this frame was rendered with, per eye, filed in the ring beside the
        // anchor so the frame that PRESENTS these pixels can compare.
        var frameTan: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)
        var framePos: (SIMD3<Float>, SIMD3<Float>) = (.zero, .zero)
        func makeEye(_ i: Int) -> q2_vr_eye_t {
            let vi = min(i, drawable.views.count - 1)
            let view = drawable.views[vi]
            let proj = drawable.computeProjection(convention: .rightUpBack, viewIndex: vi)
            let tg = tangents(proj)
            let o = view.transform.columns.3
            if i == 0 { nearC = abs(proj.columns.3.z) }
            let t4 = SIMD4<Float>(tg.l, tg.r, tg.u, tg.d)
            let p3 = SIMD3<Float>(o.x, o.y, o.z)
            if i == 0 { frameTan.0 = t4; framePos.0 = p3 } else { frameTan.1 = t4; framePos.1 = p3 }
            var e = q2_vr_eye_t()
            e.ofsRight = o.x
            e.ofsUp = o.y
            e.ofsFwd = -o.z
            e.tanL = tg.l; e.tanR = tg.r
            e.tanU = tg.u; e.tanD = tg.d
            // [R10 item 2] THIS view's own near plane, not eye 0's. The engine renders each eye
            // with it and the composite converts each eye's depth against it; taking one eye's
            // for both is correct only for as long as the two views agree, and nothing promises
            // they do.
            e.znear_m = abs(proj.columns.3.z)
            // The simulator reports views = 1 with an identity view transform, so both
            // "eyes" would be the same camera. Synthesise the injected IPD instead: without
            // it there is no stereo to assert on the simulator at all, and the honest claim
            // a sim run makes is about the RENDERER's eye pair, never about views = 2.
            if drawable.views.count < 2 {
                let half = Q2_VR_SimIPD() * 0.5
                e.ofsRight += (i == 0 ? -half : half)
            }
            return e
        }
        pose.eye.0 = makeEye(0)
        pose.eye.1 = makeEye(1)
        pose.znear_m = (nearC > 0.001 && nearC < 5) ? nearC : 0.1

        // ---- the hands, in the head's breath (R4) ---------------------------------------
        // Sampled HERE and nowhere else: inside the same frame, against the same yaw-only
        // base, riding the same frame id. A hand polled on another thread at another instant
        // disagrees with the camera it is drawn against by exactly the amount the player moved
        // in between — a disagreement visible only while they move, which is the hardest class
        // of bug this campaign has already paid for once.
        var hands = (q2_vr_hand_t(), q2_vr_hand_t())
        withUnsafeMutablePointer(to: &hands) { p in
            p.withMemoryRebound(to: q2_vr_hand_t.self, capacity: 2) { h in
                Q2_VR_HandsCompose(baseFromWorld ?? matrix_identity_float4x4,
                                   baseFromWorld != nil ? 1 : 0, h)
            }
        }
        pose.hand = hands

        let id = Q2_VR_Publish(&pose)
        // [R8] The anchor is filed under the id the engine will render with, so whichever
        // frame's pixels come back out of the publish queue can be matched to the head they
        // were drawn from. Filed even when the anchor is nil: an absent entry and an entry
        // with no anchor mean the same thing to the lookup, and one write keeps the ring's
        // slot from holding a much older frame's anchor under a colliding index.
        poseRing[Int(id % UInt64(Q2VRRenderer.kPoseRing))] = (id, anchorObj, frameTan, framePos)
        // <=14 ms. On timeout the previous pair is re-presented against the anchor THAT
        // pair was rendered with: a dropped frame then costs latency, never a jolt.
        // [R11] The wait, timed. `Q2VR_SHELL_WAIT_MS` is 14: a wait whose mean approaches it
        // is the compositor pacing itself on the engine, not on the display.
        // [R17] FREE-RUN (default). The wait bought nothing: the pair this frame presents is
        // the last GPU-COMPLETE one, published one to two frames behind the engine's CPU
        // submit (VRANCHOR lag=1 on device), so a 14 ms wait only delayed presenting the
        // pair that was already there — past the layer's rendering deadline on a 120 Hz
        // headset. Now the loop presents at the layer's own rate: publish this frame's pose
        // for the engine, present the newest complete pair against ITS anchor, done. The
        // engine paces itself on the pose stream (Q2_VR_PoseDivisor). `q2vrfreerun 0` is the
        // old rendezvous, for the A/B.
        let waitT0 = CACurrentMediaTime()
        let freeRun = Q2_VR_FreeRun() != 0
        let fresh = freeRun ? true : Q2_VR_WaitRendered(id)
        let waited = CACurrentMediaTime() - waitT0
        // Capped: the drain below runs inside the once-a-second VRANCHOR block, which is
        // gated on a published pair — so before the first publish these would grow forever.
        if clockWaits.count < 4096 { clockWaits.append(waited) }
        if waited > clockWaitMax { clockWaitMax = waited }
        if !fresh { clockTimeouts += 1 }
        // The LAYER's own period, from the drawable's presentation time and nothing of ours.
        if clockPrevPresent > 0 {
            let dt = t - clockPrevPresent
            if dt > 0.0005 && dt < 1.0 && clockPeriods.count < 4096 { clockPeriods.append(dt) }
        }
        clockPrevPresent = t

        // ---- arbitration ---------------------------------------------------------------
        // ONE predicate, asked of the engine side, so the compositor and the engine frame
        // cannot disagree about which surface this frame belongs on.
        let isWorld = Q2_VR_PresentIsWorld() != 0
        if isWorld != wasWorld {
            wasWorld = isWorld
            // Leaving world mode drops the panel anchor, so a menu re-opens in front of
            // wherever the player is looking NOW rather than where they were an hour ago.
            panelAnchor = nil
        }
        if !isWorld, panelAnchor == nil, let a = anchor { panelAnchor = a }

        // The anchor this frame submits is decided BELOW, once the published pair is in
        // hand — see [R8]. `fresh` still matters, but only as a symptom counter: freshness
        // is a fact about the CPU, and the anchor has to be a fact about the pixels.
        _ = fresh

        // [R7a item 2] ONE SNAPSHOT, not four reads. Four separate accessor calls could be
        // interrupted by a publish and pair this frame's colour with the next frame's depth —
        // a reprojection error that presents as a tracking bug. The seqlock read on the engine
        // side makes the set whole or makes it retry.
        var pubC0: UnsafeMutableRawPointer?, pubC1: UnsafeMutableRawPointer?
        var pubD0: UnsafeMutableRawPointer?, pubD1: UnsafeMutableRawPointer?
        var pubUI: UnsafeMutableRawPointer?
        var pairPoseId: UInt64 = 0
        var pairSerial: UInt32 = 0
        var pairSlot: Int32 = -1
        // [R14] The decode constants and the publish fence come out of the SAME seqlock read
        // as the textures. Before this the composite read `q2vr.znear`/`q2vr.zfar_used` live
        // off the engine thread while decoding a pair up to three frames old — and `zfar_used`
        // changes on every map load, so a pair presented across a load reprojected the whole
        // world at the wrong distance. `pairDC.zfar <= 0` means nothing has been published yet
        // (or the read tore) and the live values below are the documented fallback.
        var pairDC = q2_vr_depthconst_t()
        var pairFence: UnsafeMutableRawPointer?
        var pairFenceVal: UInt64 = 0
        VID_iOS_XR3_AcquirePublished(&pubC0, &pubC1, &pubD0, &pubD1, &pubUI, &pairPoseId,
                                     &pairSerial, &pairSlot, &pairDC, &pairFence, &pairFenceVal)
        // [R9 item 1] HOLD THE RING SLOT for as long as this command buffer can touch those
        // textures. The engine's in-flight gate releases BeginEye the instant the NEXT pair
        // publishes, so without this it starts overwriting the slot the compositor is still
        // sampling — torn depth, which reprojects as doubled edges for a flash on head turn.
        // There is no early return between here and `cmd.commit()` below; the release rides
        // that command buffer's completion handler, and a slot retained but never released
        // costs the engine a 200 ms self-heal every frame, so that pairing is load-bearing.
        VID_iOS_XR3_SlotRetain(pairSlot)

        // [R8] THE ANCHOR TRAVELS WITH THE PIXELS. The donors state the test as a question:
        // "did the imagery this frame will PRESENT get taken this frame?" — and that, not
        // "was the rendezvous fresh", decides which anchor is truthful to submit. In world
        // mode submit the anchor the acquired pair was rendered against; if the ring no
        // longer holds it (or it was never tracked) fall back to the last anchor actually
        // presented and count it, because a wrong anchor is worse than a repeated one.
        // A NON-world frame submits the LIVE anchor as before: the panel is world-locked to
        // the room through its own captured `panelAnchor`, not to the head.
        var presentedAnchor: DeviceAnchor? = nil
        if isWorld && Q2_VR_AnchorMode() == 1 {
            // [R17] `q2vranchor 1`: the LIVE anchor, deliberately wrong for old pixels — the
            // control for the freeze test (a frozen pair submitted against the live anchor
            // must read as head-locked).
            presentedAnchor = anchorObj ?? lastGoodAnchor
        } else if isWorld {
            let slot = poseRing[Int(pairPoseId % UInt64(Q2VRRenderer.kPoseRing))]
            if pairPoseId != 0, slot.id == pairPoseId, let a = slot.anchor {
                presentedAnchor = a
            } else {
                // `pairPoseId == 0` means nothing has been published yet (entry, a resize, a
                // mode change): there are no pixels on screen to be wrong about, so it is not
                // counted. `stale` is reserved for the case that actually matters — a real
                // pair whose anchor the ring could not produce.
                if pairPoseId != 0 { staleAnchorFrames += 1 }
                presentedAnchor = lastGoodAnchor
            }
        } else {
            presentedAnchor = anchorObj
        }
        if let pa = presentedAnchor {
            drawable.deviceAnchor = pa
            // The fallback remembers only anchors a real pair was rendered against: the
            // `q2vranchor 1` control submits a deliberately wrong one and must not poison it.
            if Q2_VR_AnchorMode() != 1 { lastGoodAnchor = pa }
        }
        // [R10 item 1] THE FRUSTUM COMPARISON, in one place. `eng` is what the PRESENTED pair
        // was rendered with (out of the ring, by the pair's own pose id); `draw` is what the
        // drawable being presented into reports NOW for the same view. The composite assumes
        // these are equal — it maps the engine's image onto the drawable with a uv linear in
        // the viewport and no remap term — and nothing has ever measured them. Returns nil when
        // the ring cannot produce the pair's entry, which is the same condition `stale` counts.
        func frustumSample() -> (eng: (SIMD4<Float>, SIMD4<Float>), draw: (SIMD4<Float>, SIMD4<Float>),
                                 dtan: (Float, Float), dpos: (Float, Float))? {
            guard pairPoseId != 0 else { return nil }
            let e = poseRing[Int(pairPoseId % UInt64(Q2VRRenderer.kPoseRing))]
            guard e.id == pairPoseId else { return nil }
            func one(_ i: Int) -> (SIMD4<Float>, SIMD4<Float>, Float, Float) {
                let vi = min(i, drawable.views.count - 1)
                let proj = drawable.computeProjection(convention: .rightUpBack, viewIndex: vi)
                let tg = tangents(proj)
                let d4 = SIMD4<Float>(tg.l, tg.r, tg.u, tg.d)
                let e4 = i == 0 ? e.tan.0 : e.tan.1
                let o = drawable.views[vi].transform.columns.3
                let ep = i == 0 ? e.pos.0 : e.pos.1
                return (e4, d4, simd_abs(d4 - e4).max(),
                        simd_length(SIMD3<Float>(o.x, o.y, o.z) - ep))
            }
            let a = one(0), b = one(1)
            return ((a.0, b.0), (a.1, b.1), (a.2, b.2), (a.3, b.3))
        }

        // THE REPEAT RUN. `repeat` is the judder number: a compositor frame whose pair serial
        // did not move presented the SAME pixels again and the headset reprojected them, which
        // is exactly what "the world jitters while I turn" is made of. It outlived the R10
        // stats overlay because the once-a-second VRCLOCK line reports its longest run.
        if pairSerial != 0 && pairSerial == statsPrevSerial {
            repeatRun += 1
            if repeatRun > repeatRunMax { repeatRunMax = repeatRun }
        } else {
            repeatRun = 0
        }
        statsPrevSerial = pairSerial

        // Sampled once a second: enough to prove the pairing holds over a run without
        // putting a log write on every compositor frame. `lag` is how many rendezvous ids
        // the presented pixels trail the pose just published by — the publish latency, in
        // frames — and `stale` must not climb once a run is going.
        let nowT = CACurrentMediaTime()
        if pairPoseId != 0, nowT - lastAnchorLogTime >= 1.0 {
            lastAnchorLogTime = nowT
            let anchorLine = String(format: "VRANCHOR pub=%llu pair=%llu lag=%lld stale=%d inflight=%d",
                                    id, pairPoseId, Int64(id) - Int64(pairPoseId),
                                    staleAnchorFrames, VID_iOS_XR3_InFlight())
            Q2_XR3_Log(anchorLine)
            Q2_VR_BlackBoxPin("anchor", anchorLine)
            // [R9] The ring-slot collision counter, in the same once-a-second line budget.
            // `collide` is how many engine frames found the compositor still on their slot;
            // `heal` must stay 0 (it means a consumer never released one).
            var sf: Int32 = 0, sw: Int32 = 0, sh: Int32 = 0
            VID_iOS_XR3_SlotStats(&sf, &sw, &sh)
            let slotLine = String(format: "VRSLOT collide=%d/%d heal=%d", sw, sf, sh)
            Q2_XR3_Log(slotLine)
            Q2_VR_BlackBoxPin("slot", slotLine)
            // [R10 item 1] THE LINE THE DIAGNOSIS ASKED FOR. If either `dtan` or `dpos` is
            // non-zero on a device — and especially if the two eyes differ — the composite's
            // unguarded frustum assumption is the jitter and the uv remap is the fix. If both
            // read 0 while the artefact is still reported, that mechanism is dead and the
            // publish lag on the VRANCHOR line above is the quantity to act on. On the
            // SIMULATOR both read 0 by construction: `views.count == 1`, so every eye gets one
            // static set of tangents and there is nothing that can drift.
            if let f = frustumSample() {
                Q2_XR3_Log(String(format:
                    "VRFRUSTUM e0 eng=(%.4f,%.4f,%.4f,%.4f) draw=(%.4f,%.4f,%.4f,%.4f) dtan=%.5f dpos=%.4fm " +
                    "e1 eng=(%.4f,%.4f,%.4f,%.4f) draw=(%.4f,%.4f,%.4f,%.4f) dtan=%.5f dpos=%.4fm",
                    f.eng.0.x, f.eng.0.y, f.eng.0.z, f.eng.0.w,
                    f.draw.0.x, f.draw.0.y, f.draw.0.z, f.draw.0.w, f.dtan.0, f.dpos.0,
                    f.eng.1.x, f.eng.1.y, f.eng.1.z, f.eng.1.w,
                    f.draw.1.x, f.draw.1.y, f.draw.1.z, f.draw.1.w, f.dtan.1, f.dpos.1))
            } else {
                Q2_XR3_Log("VRFRUSTUM unavailable (the ring has no entry for the presented pair)")
            }
            // [R11] THE PACING LINE. `perms`/`perhz` is the LAYER's cadence — the median of
            // consecutive presentation-time deltas, which no code of ours contributes to — and
            // `waitms`/`waitmax`/`timeouts` is how much of the frame we spend blocked on the
            // engine. If perhz reads ~90 while PACENOW reads comphz 60, the compositor is
            // being paced by our own wait; if perhz itself reads 60, the layer is running at
            // 60 and the engine is not the reason.
            let med: (inout [Double]) -> Double = { a in
                guard !a.isEmpty else { return 0 }
                a.sort(); return a[a.count / 2]
            }
            var pers = clockPeriods, wts = clockWaits
            let mp = med(&pers)
            let mw = wts.isEmpty ? 0 : wts.reduce(0, +) / Double(wts.count)
            let (lateN, lateTotal) = lateBox.drain()
            Q2_VR_NoteLayerPeriod(mp)   // [R17] the engine's pose divisor follows the layer
            // [R16] `mainticks` is APPENDED at the very end (the file's own rule): main-thread
            // display-link ticks that fired while the VR engine thread owned the frame. It is
            // 0 on a healthy session; any other value means the link was unpaused behind VR's
            // back and two threads were about to drive the engine — the per-entry coin flip
            // behind the duplicate-world flicker. The MAINTICK line names the culprit.
            // [R14b] APPENDED AT THE END, never inserted (the file's own rule): `mem` is the
            // app's physical footprint over the memory this process has left before jetsam,
            // and `peak` the high-water footprint since launch. This is the once-a-second
            // number that will explain the next device-side death the way 1.0.11.17's could
            // not — its log simply ends, because a jetsam kill writes nothing itself.
            var memCur: Float = 0, memPeak: Float = 0, memAvail: Float = 0
            Q2_VR_MemStats(&memCur, &memPeak, &memAvail)
            // [R17] APPENDED: `freerun`/`div`/`depth`/`anchor`/`freeze`/`mono` are the A/B
            // switches as the compositor read them this second. The line is also PINNED so
            // `q2vrpace` can echo it: one console command, the whole pacing picture.
            let clockLine = String(format:
                "VRCLOCK frames=%d permedms=%.3f perhz=%.1f waitmeanms=%.3f waitmaxms=%.3f timeouts=%d/%d " +
                "repmax=%d late=%d/%d mem=%.0fMB/%.0fMB peak=%.0fMB mainticks=%u " +
                "freerun=%d div=%d depth=%d anchor=%d freeze=%d mono=%d",
                clockPeriods.count, mp * 1000.0, mp > 0.0001 ? 1.0 / mp : 0.0,
                mw * 1000.0, clockWaitMax * 1000.0, clockTimeouts, clockWaits.count,
                repeatRunMax, lateN, lateTotal, memCur, memAvail, memPeak,
                Q2_VR_MainTicksInVR(),
                Q2_VR_FreeRun(), Q2_VR_PoseDivisor(), Q2_VR_DepthMode(), Q2_VR_AnchorMode(),
                Q2_VR_Freeze(), Q2_VR_Mono())
            Q2_XR3_Log(clockLine)
            Q2_VR_BlackBoxPin("clock", clockLine)
            // [R14] THE PUBLISH-FENCE LINE. `mode` is what `q2vrpubfence` last latched and
            // `fence_us` the CPU cost of the pre-sync step it added (0 in modes 0 and 3, which
            // add nothing on the engine thread). Reading the stats RESETS the window, so this
            // is the only reader.
            var fmean: Double = 0, fmax: Double = 0
            VID_iOS_XR3_PubFenceStats(&fmean, &fmax)
            Q2_XR3_Log(String(format: "VRPUB mode=%d fence_us=%.0f/%.0f",
                              VID_iOS_XR3_PubFence(), fmean, fmax))
            clockPeriods.removeAll(keepingCapacity: true)
            clockWaits.removeAll(keepingCapacity: true)
            clockWaitMax = 0
            clockTimeouts = 0
            repeatRunMax = 0
        }

        // [R21] THE R10 STATS BLOCK IS GONE. It composed a nine-line readout here once a
        // second and handed it to the engine as a string; the row that turned it on has been
        // replaced by the FPS Counter row, which is the engine's own `draw cl_fps` object and
        // needs nothing from this side. [R22] The C plumbing is gone too: Q2_VR_StatsOn /
        // Q2_VR_SetStatsText / Q2_VR_StatsCopy are deleted and `q2vr.stats_text` is left NULL,
        // so overlay 0035's screen.c block is a predicate that never fires.
        let colorTex = pubC0.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
        let colorTex1 = pubC1.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
        let depthTex = pubD0.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
        let depthTex1 = pubD1.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
        // [R9] Allocate (or re-allocate) the private copies to match what was published, then
        // decide whether this compositor frame has NEW pixels to copy. The allocation is pure
        // — no command buffer needed — so `ready` and `hasDepth` below can be decided before
        // the encoder exists, and the blit itself is the first thing in the command buffer.
        // COLOUR is copied only when nothing else already copies it. CAS writes its own
        // private pair (`sharpTex`) and is on by default at vr_sharpen 0.5, so in the shipped
        // configuration the colour blit would be a second full-resolution copy of pixels that
        // are about to be copied anyway — pure bandwidth, and on the simulator's 5760x3240
        // eye targets enough of it to stall the producer and spike the publish lag. DEPTH is
        // always copied: nothing else reads it into a compositor-owned texture, and it is the
        // read the head-turn tearing came from.
        let sharpen = Q2_VR_Sharpen()
        let casActive = (casPipeline != nil && sharpen > 0.01)
        ensurePrivateCopies(gen: VID_iOS_XR3_EyeGeneration(), color: colorTex, depth: depthTex)
        let canCopyColor = (privColor.count == 2 && colorTex != nil && colorTex1 != nil)
        let canCopyDepth = (privDepth.count == 2 && depthTex != nil && depthTex1 != nil)
        let doCopyColor = !casActive && canCopyColor
                          && (pairSerial != lastColorSerial || !haveColorCopy)
        let doCopyDepth = canCopyDepth && (pairSerial != lastDepthSerial || !haveDepthCopy)
        let colorCopyLive = !casActive && haveColorCopy && pairSerial == lastColorSerial
        let ready = colorTex != nil && colorTex1 != nil

        var params = EyeParams()
        // [R14] THE CONSTANTS THAT RIDE THE PAIR. The engine captured these at the end of the
        // frame that rendered these pixels; the live reads are kept only as the fallback for
        // "nothing published yet", which is the one case in which there are no pixels on
        // screen to be wrong about.
        let haveDC = pairDC.zfar > 0
        if haveDC {
            params.znear = pairDC.znear
            params.zfar = pairDC.zfar
            params.worldScale = pairDC.worldScale > 0.001 ? pairDC.worldScale : Q2_VR_WorldScale()
        } else {
            var zn: Float = 2, zf: Float = 4096
            VID_iOS_XR3_DepthParams(&zn, &zf)
            params.znear = zn
            params.zfar = zf
            params.worldScale = Q2_VR_WorldScale()
        }
        params.nearC = pose.znear_m
        params.depthFloor = Q2_VR_DepthFloor()
        params.hasDepth = (doCopyDepth || (haveDepthCopy && pairSerial == lastDepthSerial)) ? 1 : 0
        // [R17] `q2vrdepth 0`: the constant-2m fallback on demand. The depth copy is still made
        // (so flipping back is instant); only the shader's use of it is switched off.
        if Q2_VR_DepthMode() == 0 { params.hasDepth = 0 }
        if frames == 30 {
            // A one-shot line that states IN THE LOG whether real per-pixel depth or the
            // constant fallback is in use. This is what stops "depth is working" from being
            // an assumption nobody ever checked.
            Q2_XR3_Log(String(format: "VRDEPTH source=%@ znear=%.2fu zfar=%.1fu nearC=%.4fm scale=%.1fu_per_m floor=%.6f",
                              params.hasDepth != 0 ? "per_pixel" : "constant_2m",
                              params.znear, params.zfar, params.nearC, params.worldScale, params.depthFloor))
        }

        // [R8] The HUD and the panel are composited into the SAME submitted frame as the eye
        // pair, so they must be placed against the SAME head the compositor will reproject
        // that frame against. Placing them against the live anchor while the eyes rode a
        // presented (older) one made the HUD swim against the world by the publish latency.
        let head = presentedAnchor?.originFromAnchorTransform ?? anchor ?? matrix_identity_float4x4
        // THE PANEL SUB-RECT (R3). The engine draws the non-world 2D stream into a 16:9
        // sub-rect of the eye texture rather than into the whole nearly-square thing, which
        // is what made the menus square on the first headset build. Ask the engine for the
        // rect it actually used — never assume 16:9 here — and both the quad's shape and its
        // texture coordinates follow from that one number.
        var prw: Int32 = 0, prh: Int32 = 0
        VID_iOS_XR3_PanelRect(&prw, &prh)
        var etw: Int32 = 0, eth: Int32 = 0
        VID_iOS_XR3_EyeSize(&etw, &eth)
        let panelAspect: Float = (prw > 0 && prh > 0) ? Float(prw) / Float(prh)
                               : ((etw > 0 && eth > 0) ? Float(etw) / Float(eth) : 1.0)
        var panelUV = SIMD4<Float>(1, 1, 0, 0)
        if prw > 0, prh > 0, etw > 0, eth > 0 {
            panelUV = SIMD4<Float>(Float(prw) / Float(etw), Float(prh) / Float(eth), 0, 0)
        }
        let panelMVPBase = panelModel(head: panelAnchor ?? head, aspect: panelAspect)
        // The in-VR HUD surface. Head-locked at ~1.75 m against the LIVE head, so it goes
        // where the player looks; the panel fallback keeps its own captured anchor because a
        // menu that follows your head is a menu you cannot look away from.
        //
        // R3: its vertical anchor is the HUD Position row (High / Low / Off — the "HUD needs
        // customization" ask). Off suppresses the HUD only: menus and the console are
        // NON-world frames and reach the player through the panel above, so one control
        // cannot accidentally take the menus away with the health bar.
        // From the SAME snapshot as the eye pair (R7a): the HUD quad is composited over pixels
        // from one engine frame and must not come from another.
        let uiTex = Q2_VR_UIVisible() != 0
            ? pubUI.map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! MTLTexture }
            : nil
        let pullTarget: Float = Q2_VR_WheelOpenMirror() != 0 ? Q2_VR_WheelPull() : 1.0
        wheelPullEase += (pullTarget - wheelPullEase) * 0.11
        if abs(pullTarget - wheelPullEase) < 0.002 { wheelPullEase = pullTarget }
        let uiDist = Q2_VR_UIDistance() * wheelPullEase
        // R5 / Q-VR9: THE HUD SUB-RECT. The HUD used to be laid out for the whole UI texture,
        // which is eye-shaped — nearly square — so health and ammo sat at the corners of a
        // square. It is now composed into a widescreen sub-rect of the same texture, exactly
        // as the panel is, and both the quad's shape and its texture coordinates come from
        // the rect the ENGINE reports rather than from a constant here. 0x0 means the engine
        // did not switch (`q2vrhudwide 0`, or the shape is not up yet) and the old whole-
        // texture behaviour is what to present — no separate code path for it.
        var urw: Int32 = 0, urh: Int32 = 0
        VID_iOS_XR3_UIRect(&urw, &urh)
        let uiAspect: Float = (urw > 0 && urh > 0) ? Float(urw) / Float(urh)
                            : ((etw > 0 && eth > 0) ? Float(etw) / Float(eth) : 1.0)
        // R8 follow-up: HUD Size above the LAYOUT cap arrives here instead. The engine has
        // already re-laid the HUD out for as much of the row as its 320-unit status strip can
        // carry (Q2_VR_HudSize, capped); the surplus is a straight magnification of this
        // quad's angular extent. Applied as a scale on the extents, NOT on `degreesAcross` —
        // half-width is dist*tan(deg/2), so doubling the angle does not double the size — and
        // it scales about the quad's CENTRE, which is the point HUD Height positions, so the
        // two rows stay independent.
        let uiModel = quadModel(head: head, dist: uiDist, degreesAcross: 40,
                                aspect: uiAspect, heightOffset: Q2_VR_UIHeightOffset(),
                                extentScale: max(1.0, Q2_VR_HudMagnify()))
        var uiUV = SIMD4<Float>(1, 1, 0, 0)
        if urw > 0, urh > 0, etw > 0, eth > 0 {
            uiUV = SIMD4<Float>(Float(urw) / Float(etw), Float(urh) / Float(eth), 0, 0)
        }
        // Reverse-Z: the compositor's depth is nearC / distance_in_metres.
        var uiParams = SIMD4<Float>(min(1.0, pose.znear_m / max(uiDist, 0.05)), 0, 0, 0)

        let cmd = queue.makeCommandBuffer()!
        // [R14] THE CROSS-QUEUE WAIT (`q2vrpubfence 3`, the default). ANGLE's Metal queue and
        // this one have NO ordering between them: the only thing that has ever separated
        // "eye 1's fragments have retired" from "the compositor is sampling that slot" is the
        // CPU shared-event listener that arms the publish. This states the dependency to the
        // GPU — the same event, the same value, encoded before the blit that copies the pair
        // and before anything samples it. It cannot deadlock: the pair is published from
        // inside the listener block, so the value is already signalled by the time this code
        // can see it, and epoch invalidation/teardown clears the slot to nil, which is a
        // no-wait, not a stall. When the listener was never early this costs nothing.
        if VID_iOS_XR3_PubFence() == 3, let fp = pairFence, pairFenceVal > 0,
           let ev = Unmanaged<AnyObject>.fromOpaque(fp).takeUnretainedValue() as? MTLSharedEvent {
            cmd.encodeWaitForEvent(ev, value: pairFenceVal)
        }
        // [R9] Paired with the SlotRetain above. Every path from here presents through this
        // one command buffer, so this handler is the single release point.
        let releaseSlot = pairSlot
        // [R14] `late` rides the same handler: the drawable's own presentation time is the
        // deadline this command buffer had to beat, and `gpuEndTime` is when it actually
        // finished. Counted, never logged — this fires on Metal's thread.
        let lateDeadline = t
        let lateSink = lateBox
        cmd.addCompletedHandler { cb in
            VID_iOS_XR3_SlotRelease(releaseSlot)
            lateSink.note(cb.gpuEndTime > lateDeadline)
            // [R21] The compositor's own GPU cost, from the same handler and the same command
            // buffer the `late` verdict comes from — the only place Metal reports it. The C
            // side accumulates it (an atomic add, no logging on Metal's thread) and VRGPU
            // reports it as comp_ms.
            Q2_VR_NoteCompositorGpu((cb.gpuEndTime - cb.gpuStartTime) * 1000.0)
        }

        // ---- copy the published pair into textures this compositor owns -------------------
        // FIRST thing in the command buffer, and only when the publish serial says the pair is
        // new. Everything below samples the copies and never the engine's ring, so the engine
        // reusing a slot cannot tear a read that is already encoded — and the slot retain above
        // covers the copy itself, which is the one read that does touch the ring.
        if doCopyColor || doCopyDepth, let blit = cmd.makeBlitCommandEncoder() {
            if doCopyColor, let c0 = colorTex, let c1 = colorTex1 {
                blit.copy(from: c0, to: privColor[0])
                blit.copy(from: c1, to: privColor[1])
                haveColorCopy = true
                lastColorSerial = pairSerial
            }
            if doCopyDepth, let d0 = depthTex, let d1 = depthTex1 {
                blit.copy(from: d0, to: privDepth[0])
                blit.copy(from: d1, to: privDepth[1])
                haveDepthCopy = true
                lastDepthSerial = pairSerial
            }
            blit.endEncoding()
        }
        // Colour: the copy when one was made, otherwise the engine's own texture — safe
        // because this command buffer holds the ring slot and BeginEye waits on it.
        let srcC0: MTLTexture? = (doCopyColor || colorCopyLive) ? privColor[0] : colorTex
        let srcC1: MTLTexture? = (doCopyColor || colorCopyLive) ? privColor[1] : colorTex1
        // Depth: ALWAYS the compositor's copy. Never the engine's.
        let haveD = (doCopyDepth || (haveDepthCopy && pairSerial == lastDepthSerial))
        let srcD0: MTLTexture? = haveD ? privDepth[0] : nil
        let srcD1: MTLTexture? = haveD ? privDepth[1] : nil

        // ---- sharpen the eye pair, ONCE per published engine frame -----------------------
        // Not per compositor frame: the compositor runs at ~90 Hz and the engine slower, so
        // re-sharpening an unchanged pair would burn two full-resolution compute passes on the
        // GPU the engine needs. Same gate the 3D panel uses, for the same reason.
        var eyeSrc0 = srcC0, eyeSrc1 = srcC1
        if let cas = casPipeline, sharpen > 0.01, let c0 = srcC0, let c1 = srcC1 {
            let gen = VID_iOS_XR3_EyeGeneration()
            if gen != lastSharpGen || sharpTex.count != 2
                || sharpTex[0].width != c0.width || sharpTex[0].height != c0.height {
                lastSharpGen = gen
                lastSharpFrame = -1
                sharpTex = (0..<2).compactMap { _ in
                    let td = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: c0.pixelFormat, width: c0.width, height: c0.height,
                        mipmapped: false)
                    td.usage = [.shaderRead, .shaderWrite]
                    td.storageMode = .private
                    return device.makeTexture(descriptor: td)
                }
            }
            if sharpTex.count == 2 {
                // [R9] Keyed on the publish serial from the SAME seqlock snapshot as the
                // textures. The old key was `VID_iOS_XR3_FramesRendered()`, read outside the
                // snapshot: a publish landing in between made the shell sharpen the OLD pair,
                // stamp the NEW count, and then skip the re-sharpen next frame — frame N colour
                // presented against frame N+1 depth and anchor. Re-run whenever the copy was
                // refreshed (the copies are what CAS reads), never on an unchanged pair.
                let pubCount = Int32(bitPattern: pairSerial)
                if pubCount != lastSharpFrame, let ce = cmd.makeComputeCommandEncoder() {
                    var s = sharpen
                    ce.setComputePipelineState(cas)
                    for (i, src) in [c0, c1].enumerated() {
                        ce.setTexture(src, index: 0)
                        ce.setTexture(sharpTex[i], index: 1)
                        ce.setBytes(&s, length: MemoryLayout<Float>.size, index: 0)
                        ce.dispatchThreadgroups(
                            MTLSize(width: (src.width + 7) / 8, height: (src.height + 7) / 8, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                    }
                    ce.endEncoding()
                    lastSharpFrame = pubCount
                }
                // Only sample the sharpened copy once something has been written into it —
                // before the first dispatch it is uninitialised private memory, which reads
                // as garbage and not as black.
                if lastSharpFrame >= 0 { eyeSrc0 = sharpTex[0]; eyeSrc1 = sharpTex[1] }
            }
        }
        for (i, view) in drawable.views.enumerated() {
            let tmap = view.textureMap
            let texIdx = min(tmap.textureIndex, drawable.colorTextures.count - 1)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.colorTextures[texIdx]
            rpd.colorAttachments[0].slice = tmap.sliceIndex
            rpd.colorAttachments[0].loadAction = .clear
            // Full immersion: there is no passthrough behind the world, so the clear is
            // opaque black. (An alpha-0 clear is a MIXED-immersion affordance and there is
            // no surroundings dimming to apply here either.)
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = drawable.depthTextures[texIdx]
            rpd.depthAttachment.slice = tmap.sliceIndex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 0.0      // reverse-Z: 0 = infinitely far
            rpd.depthAttachment.storeAction = .store  // the compositor rejects what it cannot reproject
            if !drawable.rasterizationRateMaps.isEmpty {
                rpd.rasterizationRateMap =
                    drawable.rasterizationRateMaps[min(texIdx, drawable.rasterizationRateMaps.count - 1)]
            }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setViewport(tmap.viewport)
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)
            if ready {
                // The eye path samples the SHARPENED copy when there is one; the panel path
                // samples the engine texture directly, because a menu is text on a flat
                // surface and CAS on text is ringing, not crispness.
                let src = (isWorld ? (i == 0 ? eyeSrc0 : eyeSrc1) : (i == 0 ? srcC0 : srcC1))
                          ?? srcC0!
                if isWorld {
                    // [R10 item 2] THIS EYE'S near plane. The depth conversion is
                    // `nearC / distance_in_metres`, and `nearC` has to be the constant the
                    // ENGINE rendered this eye with — which is now this view's own projection
                    // rather than eye 0's for both. The pose-level value stays as the fallback
                    // for a pair published before the per-eye field existed.
                    // [R14] ... and taken from the PUBLISHED pair rather than from the pose
                    // this compositor frame just built, which belongs to a frame the engine
                    // has not rendered yet. `pose` stays the fallback for a pair published
                    // before the field existed, or a torn read.
                    let dcn = (i == 0 ? pairDC.nearC.0 : pairDC.nearC.1)
                    let zn = dcn > 0.001 ? dcn
                           : (i == 0 ? pose.eye.0.znear_m : pose.eye.1.znear_m)
                    params.nearC = (zn > 0.001 && zn < 5) ? zn : pose.znear_m
                    enc.setRenderPipelineState(eyePipeline)
                    enc.setFragmentTexture(src, index: 0)
                    if let d = (i == 0 ? srcD0 : srcD1) { enc.setFragmentTexture(d, index: 1) }
                    enc.setFragmentBytes(&params, length: MemoryLayout<EyeParams>.stride, index: 0)
                    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                    // ... and the 2D on top of it, from its own texture, at its own distance.
                    // The eye image itself carries ZERO 2D: the engine redirected the whole
                    // stream (HUD, menus, console, notify, loading, the weapon wheel's own
                    // capture) into this texture before it ever reached the eye target.
                    if let ui = uiTex, let uiPipeline {
                        enc.setRenderPipelineState(uiPipeline)
                        let worldFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
                        let worldFromEye = worldFromDevice * view.transform
                        let proj = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
                        var mvp = proj * worldFromEye.inverse * uiModel
                        enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
                        enc.setVertexBytes(&uiUV, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                        enc.setFragmentTexture(ui, index: 0)
                        enc.setFragmentBytes(&uiParams, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    }
                } else {
                    enc.setRenderPipelineState(panelPipeline)
                    let worldFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
                    let worldFromEye = worldFromDevice * view.transform
                    let proj = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
                    var mvp = proj * worldFromEye.inverse * panelMVPBase
                    enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
                    enc.setVertexBytes(&panelUV, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                    enc.setFragmentTexture(src, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            enc.endEncoding()
        }
        drawable.encodePresent(commandBuffer: cmd)
        cmd.commit()
        frame.endSubmission()

        // [R23] THE ENTRY WATCH, fed from the one place that knows all four answers about this
        // frame: whether a published pair was in hand (`ready`), whether the drawable was
        // submitted with a device anchor (without one the system has nothing to reproject and
        // shows nothing), which eye generation this side is holding, and that the pipelines
        // exist. Four relaxed atomic stores; the ENGINE thread prints the verdict.
        let shellGen = VID_iOS_XR3_EyeGeneration()
        // [R23] `q2vrfaultentry` drives the two black-entry states on demand: bit 1 says "no
        // device anchor", bit 2 "no adopted pair". It is injected HERE, into what this side
        // REPORTS, not into what it draws — so a fault run proves the verdict, the heal and
        // the recovery, and claims nothing about the picture (the simulator composites no
        // immersive content, so a black picture is not a thing it can show either way).
        let fault = Q2_VR_EntryFault()
        let haveAnchor = presentedAnchor != nil && (fault & 1) == 0
        let adopted = ready && (fault & 2) == 0
        Q2_VR_NoteArkit(trackingStateOrdinal(), 0)
        Q2_VR_NoteCompositorFrame(adopted ? 1 : 0, haveAnchor ? 1 : 0, shellGen, 1)
        maybeHeal(gen: shellGen, haveAnchor: haveAnchor, adopted: adopted)
    }

    // The panel quad, sized by the ANGLE it subtends rather than by a stored width: the VR
    // render target is eye-shaped (nearly square), not 16:9, so a half-height stored for the
    // 3D panel would put the menu's bottom row outside the field of view with nothing
    // reporting it — a donor shipped a menu with no bottom row for exactly this reason.
    // [R21] The width is the Menu Panel Size row (XR3.panelDegrees, 40...90, default 64) and
    // no longer the shipped 44-degree constant — 44 was called too small in the headset.
    // The same quad carries the menus, the console, demo playback and cinematics (they are all
    // the one non-world 2D stream, arbitrated onto this surface), so one row moves all of them
    // and there is no second panel to keep in step. `heightOffset` is untouched: the quad is
    // scaled about its centre, so the bottom row's angular position moves by only half the
    // added height and stays inside the eye's ~50-degree downward reach.
    private func panelModel(head: simd_float4x4, aspect: Float) -> simd_float4x4 {
        let deg = XR3.panelDegrees
        if deg != lastPanelDegrees {
            lastPanelDegrees = deg
            // The half-width is what the row actually buys, so log the metres rather than the
            // degrees: the sim cannot read back a composited quad, and this line is the only
            // channel a size assertion has.
            Q2_XR3_Log(String(format: "VRPANELSIZE deg=%.1f dist=3.00 halfw=%.3fm aspect=%.3f",
                              deg, 3.0 * tan(deg * Float.pi / 360.0), aspect))
        }
        return quadModel(head: head, dist: 3.0, degreesAcross: deg, aspect: aspect,
                         heightOffset: XR3.height)
    }

    // One quad builder for both surfaces. Sized by the ANGLE it subtends rather than by a
    // stored width: the VR render target is eye-shaped (nearly square), not 16:9, so a
    // half-height stored for the 3D panel would put the menu's bottom row outside the field
    // of view with nothing reporting it — a donor shipped a menu with no bottom row for
    // exactly this reason.
    //
    // R3: the ASPECT is now a parameter rather than always the eye texture's. Each surface
    // must present at the aspect the ENGINE laid its content out at, and after the panel-shape
    // change those two are different numbers — the panel is 16:9 in a sub-rect, the HUD is
    // still the eye's shape. Deriving both from the eye size was what made the menus square.
    private func quadModel(head: simd_float4x4, dist: Float, degreesAcross: Float,
                           aspect: Float, heightOffset: Float = 0,
                           extentScale: Float = 1) -> simd_float4x4 {
        let headPos = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var fwd = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        fwd.y = 0
        if simd_length(fwd) < 0.001 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = simd_normalize(fwd)
        var pos = headPos + fwd * dist
        pos.y += heightOffset
        var normal = simd_normalize(headPos - pos)
        var up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, normal))
        up = simd_cross(normal, right)
        let halfW = dist * tan(degreesAcross * Float.pi / 360.0) * extentScale
        let halfH = halfW / max(aspect, 0.2)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right * halfW, 0)
        m.columns.1 = SIMD4<Float>(up * halfH, 0)
        m.columns.2 = SIMD4<Float>(normal, 0)
        m.columns.3 = SIMD4<Float>(pos, 1)
        return m
    }
}

// [R14] A counter two threads touch: the compositor drains it once a second, Metal's
// completion thread increments it. An NSLock rather than an unguarded var because a torn
// counter would make the one number the pacing question turns on unreliable, and because
// nothing here is hot — one lock per presented frame.
final class LateFrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var late = 0
    private var total = 0
    func note(_ isLate: Bool) {
        lock.lock()
        total += 1
        if isLate { late += 1 }
        lock.unlock()
    }
    func drain() -> (Int, Int) {
        lock.lock()
        let r = (late, total)
        late = 0; total = 0
        lock.unlock()
        return r
    }
}

// A console-reachable stand-in for the Digital Crown, so the system-dismissal path can be
// asserted on a simulator that has no Crown. It runs the SAME reconciliation the layer's
// .invalidated branch runs — no more, and it says no more: what it proves is that the
// finalize is idempotent, unconditional, auto-pauses and writes the config. Whether
// visionOS actually delivers .invalidated on a real Crown press is a device question and
// stays on the QUESTIONS.md checklist.
// The entry twin of the dismissal stand-in, for the console (`q2vrenter`). It sets the
// model's mode and NOTHING else, so what a simulator drives is the same applyMode
// transition the ornament's VR button drives — a test seam beside the shipping path would
// prove nothing about the shipping path. Its whole reason to exist is that a suite case
// needing a known state BEFORE entry could otherwise only get into VR by relaunching.
@_cdecl("Q2_VR_SwiftEnterVR")
public func Q2_VR_SwiftEnterVR() {
    DispatchQueue.main.async {
        Q2_XR3_Log("VRENTER console request")
        Q2AppModel.shared.mode = .vr
    }
}

@_cdecl("Q2_VR_SwiftSystemDismiss")
public func Q2_VR_SwiftSystemDismiss() {
    DispatchQueue.main.async {
        Q2_XR3_Log("VRENDED simulated system dismissal")
        if Q2AppModel.shared.mode == .vr {
            Q2AppModel.shared.mode = .flat
        } else {
            Q2_iOS_AutoPause()
            Q2_iOS_WriteConfigSync()
        }
    }
}
