// ImmersiveApp.swift — visionOS 3D (immersive) app shell for q2repro.
// Compositor Services render loop that boots the q2repro engine and drives one Qcommon_Frame per
// compositor frame, with the engine rendering (via ANGLE) straight into the drawable's eye
// texture. M1 = MONO: render eye 0, blit to eye 1. Stereo (per-eye view/projection) is M3.
// Present path = the proven direct-render shape (whole-array load + depth clear) from the spike.
import CompositorServices
import SwiftUI
import Metal
import ARKit
import GameController
import UIKit

// Claims the game controller from visionOS's default gaze-pinch handling (which otherwise
// converts pad presses into UI events and withholds them from GCController). quake3e's visionOS
// port needs this too. Hosted invisibly in the launcher window so the pad is claimed app-wide.
struct PadClaim: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        if #available(visionOS 2.0, *) {
            let it = GCEventInteraction()
            it.handledEventTypes = .gamepad
            v.addInteraction(it)
        }
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension LayerRenderer.Clock.Instant {
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds / 1_000_000_000) / TimeInterval(NSEC_PER_SEC)
    }
}

// In-window diagnostics (device log capture is unreliable on this headset).
final class XRStats {
    static let shared = XRStats()
    private let lock = NSLock()
    private var log: [String] = ["waiting…"]
    private var frames = 0
    func note(_ s: String) { lock.lock(); log.append(s); if log.count > 6 { log.removeFirst() }; lock.unlock() }
    func tick(_ extra: String = "") {
        lock.lock(); frames += 1; let f = frames; lock.unlock()
        if f == 1 || f % 90 == 0 { note("frame \(f) \(extra)") }
    }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return log.joined(separator: " › ") }
}

// Crash breadcrumbs: written to disk (overwritten) at each risky step so that after a silent
// crash we can reopen the app and read the LAST breadcrumb — the call that died. Device crash
// logs are unavailable on this headset (devicectl 7000), so this is our stack trace.
final class XRTrace {
    static let shared = XRTrace()
    private let lock = NSLock()
    private var lines: [String] = []
    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("xrtrace.txt")
    }
    func reset() { lock.lock(); lines = []; lock.unlock(); try? Data().write(to: Self.url) }
    func log(_ s: String) {
        lock.lock(); lines.append(s); if lines.count > 40 { lines.removeFirst() }
        let text = lines.joined(separator: "\n"); lock.unlock()
        try? text.data(using: .utf8)?.write(to: Self.url)   // flush every step → survives a crash
    }
    static func previous() -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "(no trace yet)" }
}

// Live-tunable stereo comfort settings, persisted in UserDefaults so they survive relaunch and
// can be read from the render thread (UserDefaults reads are thread-safe). Defaults and ranges
// are informed by the quake3e visionOS port's proven values. The launcher exposes sliders; the
// renderer reads these each frame, so tuning is live while immersed.
enum XRSettings {
    private static let d = UserDefaults.standard
    static func f(_ k: String, _ def: Float) -> Float { d.object(forKey: k) == nil ? def : d.float(forKey: k) }
    static func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    // "3D depth / intensity": half the eye separation in world units (total = 2×). Bigger = more depth.
    static var separation: Float { f("xr_sep", 1.1) }      // range 0.3 … 2.5 (≈IPD at inch scale; vkQuake ships 2.5 total)
    // Convergence ("Crosshair Distance", world units): the depth that sits exactly ON the screen.
    static var convergence: Float { f("xr_conv", 128) }    // range 32 … 512; vkQuake settled on 128
    static var distance: Float   { f("xr_dist", 2.8) }     // metres in front (quake3e uses 3.6)
    static var halfWidth: Float  { f("xr_sizeW", 1.6) }    // screen half-width in metres (height 4:3-derived)
    static var height: Float     { f("xr_height", 0.0) }   // metres above eye level
    static var hideGun: Bool     { b("xr_hidegun", false) } // with convergence the gun fuses fine — shown by default
    static var recenterCount: Int { UserDefaults.standard.integer(forKey: "xr_recenter") } // bump = re-place screen
}

struct XRConfig: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .rgba16Float
        configuration.isFoveationEnabled = false            // direct GL write can't use the rate map (M-later)
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
    }
}

struct XRContent: CompositorContent {
    var body: some CompositorContent {
        CompositorLayer(configuration: XRConfig()) { @MainActor layerRenderer in
            XRStats.shared.note("closure entered")
            let r = XRRenderer(layerRenderer)
            Thread { r.renderLoop() }.start()
        }
    }
}

@main
struct ImmersiveQ2App: App {
    var body: some Scene {
        WindowGroup { XRLauncher() }
        ImmersiveSpace(id: "q2") { XRContent() }
            .immersionStyle(selection: .constant(.full), in: .full)
    }
}

struct XRLauncher: View {
    @Environment(\.openImmersiveSpace) private var openSpace
    @State private var status = "not opened"
    @State private var hasData = true          // set on appear via Q2_XR_HasData()
    // 3D comfort settings (keys match XRSettings; the render thread reads them live).
    @AppStorage("xr_hidegun")  private var hideGun = false
    @AppStorage("xr_sep")      private var sep    = 1.1
    @AppStorage("xr_conv")     private var conv   = 128.0
    @AppStorage("xr_dist")     private var dist   = 2.8
    @AppStorage("xr_sizeW")    private var sizeW  = 1.6
    @AppStorage("xr_height")   private var height = 0.0
    @AppStorage("xr_recenter") private var recenter = 0

    @ViewBuilder private func slider(_ label: String, _ value: Binding<Double>,
                                     _ range: ClosedRange<Double>, _ fmt: String,
                                     scale: Double = 1.0) -> some View {
        HStack {
            Text(label).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue * scale)).frame(width: 64, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
        }
    }

    static func engineLogTail() -> String {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // Find the most recently modified *.log anywhere under the container (the engine may name
        // it qconsole.log or a dated file under baseq2/logs/).
        var logs: [(URL, Date)] = []
        if let en = fm.enumerator(at: docs, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let u as URL in en where u.pathExtension == "log" {
                let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                logs.append((u, d))
            }
        }
        if let newest = logs.max(by: { $0.1 < $1.1 })?.0,
           let s = try? String(contentsOf: newest, encoding: .utf8), !s.isEmpty {
            return "[\(newest.path.replacingOccurrences(of: docs.path, with: "…"))]\n"
                + s.split(separator: "\n").suffix(28).joined(separator: "\n")
        }
        // No log — dump the container + logs dir so we can see the data + where logs would be.
        let top = (try? fm.contentsOfDirectory(atPath: docs.path)) ?? []
        let bq = (try? fm.contentsOfDirectory(atPath: docs.appendingPathComponent("baseq2").path)) ?? []
        let lg = (try? fm.contentsOfDirectory(atPath: docs.appendingPathComponent("baseq2/logs").path)) ?? []
        return "(no *.log)\nDocuments/: \(top.joined(separator: ", "))\nbaseq2/: \(bq.joined(separator: ", "))\nbaseq2/logs/: \(lg.joined(separator: ", "))"
    }
    // Build tag so the user can confirm exactly which build is installed — the two concurrent
    // sessions' publishes collide on the minute-stamped build number, so seeing it on-screen
    // removes all doubt about "did I test the new one".
    static var buildTag: String {
        let v = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "build \(v)"
    }
    var body: some View {
        VStack(spacing: 16) {
            Text("q2repro — 3D").font(.title)
            Text(Self.buildTag).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            Text(status).font(.system(.headline, design: .monospaced))
            if !hasData {
                Text("⚠️ No game data found.\nOpen the Files app → On My Vision Pro → q2repro 3D and copy in your \u{201C}baseq2\u{201D} folder (or the \u{201C}rerelease\u{201D} folder). If the q2repro app already has your data, copy the folder straight across. Then reopen this app.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            // Last crash breadcrumb trail — the final line is the call that died last run.
            Text(XRTrace.previous().split(separator: "\n").suffix(12).joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(XRStats.shared.snapshot()).font(.system(.footnote, design: .monospaced)).foregroundStyle(.yellow)
            }
            // Live engine console tail — read the engine's own logfile (Documents/qconsole.log,
            // enabled via +set logfile 1). USE_SYSCON is 0 so Sys_ConsoleOutput is never called;
            // the logfile is the real console. The app can read its own container directly.
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                ScrollView {
                    Text(Self.engineLogTail()).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 320).padding(8)
                    .background(.black.opacity(0.4))
            }
            Button(hasData ? "Enter 3D" : "Add game data first") {
                guard hasData else { return }
                Task {
                    status = "opening…"
                    switch await openSpace(id: "q2") {
                    case .opened: status = "OPENED"
                    case .error: status = "ERROR"
                    case .userCancelled: status = "cancelled"
                    @unknown default: status = "?"
                    }
                }
            }.font(.title2).disabled(!hasData)

            DisclosureGroup("3D comfort settings") {
                VStack(alignment: .leading, spacing: 10) {
                    slider("Depth",     $sep,    0.3...2.5,  "%.0f%%", scale: 100.0 / 1.1)   // % of default
                    slider("Crosshair", $conv,   32...512,   "%.0f")   // convergence distance (world units)
                    slider("Distance",  $dist,   1.5...6.0,  "%.1fm")
                    slider("Size",      $sizeW,  0.8...4.0,  "%.1fm")
                    slider("Height",    $height, -1.5...3.0, "%.1fm")
                    Toggle("Hide weapon", isOn: $hideGun)
                    HStack(spacing: 24) {
                        Button("Recenter screen") { recenter += 1 }   // re-place in front of current head pose
                        Button("Reset to defaults") { hideGun = false; sep = 1.1; conv = 128; dist = 2.8; sizeW = 1.6; height = 0.0 }
                    }.font(.caption)
                }.padding(.vertical, 6)
            }.frame(maxWidth: 520)

            PadClaim().frame(width: 1, height: 1)   // invisible; claims the game controller
        }.padding(40)
        .task {
            // Check for game data on appear. Side effect (in Q2_XR_HasData): when data is absent
            // it writes a readme into Documents so the app shows up in Files and the user can drop
            // data in. Drives the instruction card + gates the Enter button above.
            hasData = Q2_XR_HasData()
            // Headless simulator validation: taps cannot be injected on the visionOS sim, so
            // `simctl launch` sets SIMCTL_CHILD_Q2_XR_AUTOENTER=1 and the launcher enters the
            // immersive space by itself. No effect unless the env var is set.
            if hasData, ProcessInfo.processInfo.environment["Q2_XR_AUTOENTER"] == "1" {
                status = "auto-opening…"
                switch await openSpace(id: "q2") {
                case .opened: status = "OPENED (auto)"
                case .error: status = "ERROR (auto)"
                default: status = "? (auto)"
                }
            }
        }
    }
}

// ---- math helpers (simd) ---------------------------------------------------
private func translationMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4; m.columns.3 = SIMD4<Float>(x, y, z, 1); return m
}
private func scaleMatrix(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4<Float>(x, y, z, 1))
}
// Asymmetric perspective from the compositor's per-eye tangents (left,right,top,bottom, all
// positive), right-handed eye space (-Z forward), Metal clip z in [0,1].
private func projectionMatrix(_ t: SIMD4<Float>, near n: Float, far f: Float) -> simd_float4x4 {
    let l = t.x, r = t.y, tp = t.z, b = t.w
    return simd_float4x4(
        SIMD4<Float>(2 / (l + r), 0, 0, 0),
        SIMD4<Float>(0, 2 / (tp + b), 0, 0),
        SIMD4<Float>((r - l) / (l + r), (tp - b) / (tp + b), f / (n - f), -1),
        SIMD4<Float>(0, 0, f * n / (n - f), 0))
}

final class XRRenderer {
    let layer: LayerRenderer
    let device: MTLDevice
    let queue: MTLCommandQueue
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    var booted = false

    // Two offscreen engine render targets (one per eye) and the textured-quad pipeline that
    // draws them onto a world-locked screen with correct per-eye projection.
    // 4:3 game render resolution per eye. 1280×960 was noticeably soft on the stereoscopic screen;
    // 2048×1536 (~3.1 MP ×2 eyes at 90 Hz ≈ well within the M2 budget the 2D build proves) sharpens
    // it. (Refine against the quake3e per-eye study — it may pay to match the drawable's native size.)
    let gw: Int = 2048, gh: Int = 1536
    var gameTex: [MTLTexture] = []                  // [left, right]
    var pipeline: MTLRenderPipelineState?
    var depthState: MTLDepthStencilState?
    var frozenHead: simd_float4x4?                  // head pose captured once; screen is placed relative to it
    var lastHideGun: Bool?                          // apply the cl_gun cvar only when the toggle changes
    var framesSinceUnfreeze = 0                     // ARKit's first poses are near-identity — wait to freeze
    var lastRecenter = XRSettings.recenterCount     // recenter button bumps this → re-place the screen

    init(_ layer: LayerRenderer) {
        self.layer = layer
        self.device = layer.device
        self.queue = device.makeCommandQueue()!
        XRTrace.shared.reset(); XRTrace.shared.log("init: start")
        Task { try? await self.arSession.run([self.worldTracking]) }
        buildPipeline();      XRTrace.shared.log("init: pipeline \(pipeline == nil ? "NIL" : "ok")")
        buildGameTextures();  XRTrace.shared.log("init: gameTex count=\(gameTex.count)")
    }

    private func buildGameTextures() {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                         width: gw, height: gh, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]      // GL (ANGLE) renders in, Metal samples out
        d.storageMode = .private
        for _ in 0..<2 { if let t = device.makeTexture(descriptor: d) { gameTex.append(t) } }
        if gameTex.count < 2 { XRStats.shared.note("gameTex alloc failed") }
    }

    private func buildPipeline() {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv;
                      uint layer [[render_target_array_index]]; uint vp [[viewport_array_index]]; };
        vertex VOut q2vtx(uint vid [[vertex_id]],
                          constant float4x4& mvp [[buffer(0)]],
                          constant uint& eye [[buffer(1)]]) {
            const float2 p[4]  = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            // V flipped (GL bottom-up vs Metal top-down); U NOT flipped (the quad faces the viewer,
            // so screen-left maps to texture-left — flipping U mirrors the image).
            const float2 uv[4] = { float2(0,0),   float2(1,0),  float2(0,1),  float2(1,1) };
            VOut o; o.pos = mvp * float4(p[vid], 0, 1); o.uv = uv[vid];
            o.layer = eye; o.vp = eye; return o;
        }
        fragment float4 q2frag(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float4 c = tex.sample(s, in.uv);
            // Linearize: the engine's GL output is display-encoded (gamma) color, but the
            // rgba16Float drawable is treated as LINEAR extended-range by the compositor —
            // showing gamma values as linear washes the image flat/milky. Same fix as
            // vkQuake's srgbDecode in its panel shader.
            c.rgb = pow(max(c.rgb, float3(0.0)), 2.2);
            return c;
        }
        """
        do {
            XRTrace.shared.log("pipe: makeLibrary")
            let lib = try device.makeLibrary(source: src, options: nil)
            XRTrace.shared.log("pipe: lib ok")
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = lib.makeFunction(name: "q2vtx")
            pd.fragmentFunction = lib.makeFunction(name: "q2frag")
            pd.colorAttachments[0].pixelFormat = .rgba16Float
            pd.depthAttachmentPixelFormat = .depth32Float
            // REQUIRED when the vertex shader writes [[render_target_array_index]] (layered
            // stereo rendering): Metal needs the primitive topology declared up front.
            pd.inputPrimitiveTopology = .triangle
            XRTrace.shared.log("pipe: makePSO")
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
            XRTrace.shared.log("pipe: PSO ok")
            let dsd = MTLDepthStencilDescriptor()
            dsd.depthCompareFunction = .lessEqual; dsd.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: dsd)
        } catch { XRTrace.shared.log("pipe ERR: \(error)") }
    }

    func renderLoop() {
        XRStats.shared.note("loop starting")
        while true {
            switch layer.state {
            case .paused: layer.waitUntilRunning()
            case .running: autoreleasepool { renderFrame() }
            case .invalidated: XRStats.shared.note("invalidated"); return
            @unknown default: return
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { return }
        frame.startUpdate(); frame.endUpdate()
        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard let drawable = drawables.first else { frame.endSubmission(); return }
        let t = drawable.frameTiming.presentationTime.timeInterval
        if let a = worldTracking.queryDeviceAnchor(atTimestamp: t) { drawable.deviceAnchor = a }

        let first = !booted
        // Boot the engine on the first frame — on THIS render thread, where the ANGLE context
        // becomes current (a_init runs inside Qcommon_Init).
        if !booted { XRTrace.shared.log("boot: start"); Q2_XR_Boot(); booted = true; XRTrace.shared.log("boot: done") }

        guard gameTex.count == 2, let pipeline, let depthState else { XRTrace.shared.log("guard: gameTex/pipeline missing"); frame.endSubmission(); return }
        let gwi = Int32(gw), ghi = Int32(gh)

        // STEREO: render the game twice from the same sim state — left eye (into gameTex[0]) via
        // the sim-stepping Q2_XR_Frame, then right eye (into gameTex[1]) via a 2nd render-only pass.
        // The right-eye render only happens when the engine actually rendered a WORLD this frame
        // (Q2_XR_RenderView → 0 during boot/map load/menus/console/cinematics — rendering blind
        // there tripped R_RenderFrame's world assertion and killed the app). When skipped, both
        // eyes show the left image (mono) — correct for those 2D-ish states anyway.
        // Apply the hide-gun toggle only when it changes.
        let hideGun = XRSettings.hideGun
        if hideGun != lastHideGun { Q2_XR_SetHideGun(hideGun ? 1 : 0); lastHideGun = hideGun }
        // Convergence ("Crosshair Distance") — live, before either eye renders this frame.
        Q2_XR_SetConvergence(XRSettings.convergence)

        // BOTH eyes render the complete frame (world + HUD/crosshair + menus) from the same sim
        // state — 2D lands at zero disparity (on the panel), the world recedes behind it.
        let sep = XRSettings.separation
        if first { XRTrace.shared.log("render L") }
        Q2_XR_SetStereo(-sep); VID_iOS_XR_SetEye(gameTex[0], 0, gwi, ghi); Q2_XR_Frame()
        if first { XRTrace.shared.log("render R") }
        Q2_XR_SetStereo(+sep); VID_iOS_XR_SetEye(gameTex[1], 0, gwi, ghi)
        _ = Q2_XR_RenderView()
        Q2_XR_SetStereo(0)
        // NOTE: do NOT glReadPixels the game texture — it is .private storage and ANGLE's readback
        // (Metal getBytes on a private texture) segfaults. The screen itself is the confirmation.
        if first { XRTrace.shared.log("finish") }
        VID_iOS_XR_Finish()                      // ensure ANGLE finished writing before Metal reads

        // Capture the head pose once; the screen is world-locked relative to it. Placement is
        // recomputed EVERY frame from that frozen head + the live settings, so the distance/size/
        // height sliders move the screen in real time while immersed (quake3e does the same).
        // WAIT ~30 presented frames before freezing: ARKit's first frames report success with a
        // near-identity pose — freezing on frame 1 anchored vkQuake's panel into the floor.
        // The launcher's Recenter button bumps recenterCount → re-freeze from the current pose.
        let rc = XRSettings.recenterCount
        if rc != lastRecenter { lastRecenter = rc; frozenHead = nil; framesSinceUnfreeze = 0 }
        framesSinceUnfreeze += 1
        if frozenHead == nil, framesSinceUnfreeze > 30, let a = drawable.deviceAnchor {
            frozenHead = a.originFromAnchorTransform
        }
        let head = frozenHead ?? (drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4)
        let halfW = XRSettings.halfWidth
        let halfH = halfW * Float(gh) / Float(gw)      // keep the game's 4:3 aspect (no stretch)
        let model = head * translationMatrix(0, XRSettings.height, -XRSettings.distance) * scaleMatrix(halfW, halfH, 1)
        let worldFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4
        if first { XRTrace.shared.log("present: build pass") }

        // Draw the stereo screen in ONE pass over the whole eye-texture array (the proven present
        // shape — NOT per-slice descriptors, which crash). The quad is drawn once per eye; the
        // vertex shader routes each draw to its slice/viewport via render_target_array_index.
        let cmd = queue.makeCommandBuffer()!
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.colorTextures[0]
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = drawable.depthTextures[0]
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .store
        rpd.rasterizationRateMap = drawable.rasterizationRateMaps.first
        if drawable.views.count > 1 { rpd.renderTargetArrayLength = drawable.views.count }
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { XRTrace.shared.log("encoder NIL"); frame.endSubmission(); return }
        enc.setViewports(drawable.views.map { $0.textureMap.viewport })
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthState)
        enc.setCullMode(.none)
        for (i, view) in drawable.views.enumerated() {
            let worldFromEye = worldFromDevice * view.transform
            var mvp = projectionMatrix(view.tangents, near: 0.05, far: 100) * worldFromEye.inverse * model
            var eye = UInt32(i)
            if first { XRTrace.shared.log("draw eye \(i)") }
            enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
            enc.setVertexBytes(&eye, length: MemoryLayout<UInt32>.size, index: 1)
            // Each eye always samples its own full-frame render (2D at zero disparity in both).
            enc.setFragmentTexture(gameTex[min(i, 1)], index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        if first { XRTrace.shared.log("endEncoding") }
        enc.endEncoding()
        drawable.encodePresent(commandBuffer: cmd)
        cmd.addCompletedHandler { cb in
            if cb.status != .completed { XRTrace.shared.log("cmd status=\(cb.status.rawValue)") }
        }
        if first { XRTrace.shared.log("commit") }
        cmd.commit()
        frame.endSubmission()
        if first { XRTrace.shared.log("frame 1 OK") }
        // con=1 while the boot console is still up, 0 once it's retracted into the clean game
        // view (the sim can't screenshot immersive content, so this confirms the console-close
        // from the launcher window). data= shows which game data actually won (the shadowing fix).
        XRStats.shared.tick("eyes=\(drawable.views.count) con=\(Q2_XR_ConsoleOpen()) data=\(String(cString: Q2_XR_DataMode()))")
    }
}
