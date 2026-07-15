// Standalone visionOS immersive spike (Milestone 1 of the 3D plan).
// SwiftUI ImmersiveSpace + Compositor Services render loop that clears each eye to a
// distinct color and draws a test triangle — proving the per-eye Metal pipeline on
// device before we wire ANGLE + the engine into it. No engine/ANGLE dependency yet.
import CompositorServices
import SwiftUI
import Metal
import ARKit

// The compositor needs each drawable tagged with the device (head) pose at its presentation
// time, or it discards the frame (renders but nothing shows). This converts the compositor
// clock instant to the TimeInterval ARKit's queryDeviceAnchor expects.
extension LayerRenderer.Clock.Instant {
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds / 1_000_000_000) / TimeInterval(NSEC_PER_SEC)
    }
}

// Live diagnostics surfaced in the launcher window (device log capture is unreliable on
// this headset). Thread-safe sequence log; the window POLLS snapshot() on a timer so there
// is no @Published/@ObservedObject observation subtlety to worry about.
final class RenderStats {
    static let shared = RenderStats()
    private let lock = NSLock()
    private var log: [String] = ["waiting…"]
    private var frames = 0
    func note(_ s: String) { lock.lock(); log.append(s); if log.count > 6 { log.removeFirst() }; lock.unlock() }
    func tick(_ extra: String = "") {
        lock.lock(); frames += 1; let f = frames; lock.unlock()
        if f == 1 || f % 45 == 0 { note("rendering \(f) \(extra)") }
    }
    func snapshot() -> String { lock.lock(); defer { lock.unlock() }; return log.joined(separator: " › ") }
}

struct SpikeConfig: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // rgba16Float is the compositor's native HDR color format; bgra8Unorm_srgb is not a
        // supported CompositorLayer color format and makes the immersive space fail to open.
        configuration.depthFormat = .depth32Float
        configuration.colorFormat = .rgba16Float
        configuration.isFoveationEnabled = false
        // .dedicated = one color texture per eye — matches how we render each eye separately
        // (and how ANGLE will draw into each eye texture later), vs .layered amplification.
        // .layered — the layout Spike A proved composites. colorTextures[0] is a 2D array (one
        // slice per eye); ANGLE renders into each slice via an EGL_METAL_TEXTURE_ARRAY_SLICE image.
        let layouts = capabilities.supportedLayouts(options: [])
        configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        RenderStats.shared.note("config layout=\(layouts.contains(.layered) ? "layered" : "dedicated")")
    }
}

// visionOS 26 requires the ImmersiveSpace content to be a CompositorContent that RETURNS the
// CompositorLayer from its body — a bare CompositorLayer as ImmersiveSpace content compiles
// (it's also a View) but is never driven, so the render closure never runs.
struct SpikeContent: CompositorContent {
    var body: some CompositorContent {
        CompositorLayer(configuration: SpikeConfig()) { @MainActor layerRenderer in
            RenderStats.shared.note("closure entered")
            let renderer = SpikeRenderer(layerRenderer)
            // Kick the render loop onto its own thread — the closure is @MainActor and must
            // return promptly (blocking it would hang the UI). The thread retains `renderer`.
            Thread { renderer.renderLoop() }.start()
        }
    }
}

@main
struct ImmersiveSpikeApp: App {
    var body: some Scene {
        WindowGroup {
            LauncherView()
        }
        ImmersiveSpace(id: "spike") {
            SpikeContent()
        }
        .immersionStyle(selection: .constant(.full), in: .full)
    }
}

struct LauncherView: View {
    @Environment(\.openImmersiveSpace) private var openSpace
    @State private var status = "not opened yet"
    var body: some View {
        VStack(spacing: 16) {
            Text("q2repro immersive spike").font(.title)
            Text(status).font(.system(.headline, design: .monospaced))
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(RenderStats.shared.snapshot())
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.yellow)
            }
            Button("Enter Immersive") {
                RenderStats.shared.note("button tapped")   // confirms the polling readout is live
                Task {
                    status = "opening…"
                    let r = await openSpace(id: "spike")
                    switch r {
                    case .opened:        status = "OPENED — look around"
                    case .userCancelled: status = "userCancelled"
                    case .error:         status = "ERROR opening space"
                    @unknown default:    status = "unknown result"
                    }
                }
            }
            .font(.title2)
        }
        .padding(40)
    }
}

final class SpikeRenderer {
    let layer: LayerRenderer
    let device: MTLDevice
    let queue: MTLCommandQueue
    var pipeline: MTLRenderPipelineState!
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()

    init(_ layer: LayerRenderer) {
        self.layer = layer
        self.device = layer.device
        self.queue = device.makeCommandQueue()!
        buildPipeline()
        // Start world tracking so queryDeviceAnchor returns a head pose for each drawable.
        Task { try? await self.arSession.run([self.worldTracking]) }
        RenderStats.shared.note("renderer init ok")
    }

    private func buildPipeline() {
        let lib = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = lib.makeFunction(name: "spike_vertex")
        desc.fragmentFunction = lib.makeFunction(name: "spike_fragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.depthAttachmentPixelFormat = .depth32Float
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    func renderLoop() {
        RenderStats.shared.note("loop starting")
        while true {
            switch layer.state {
            case .paused:      layer.waitUntilRunning()
            case .running:     autoreleasepool { renderFrame() }
            case .invalidated: RenderStats.shared.note("loop invalidated"); return
            @unknown default:  return
            }
        }
    }

    private func renderFrame() {
        guard let frame = layer.queryNextFrame() else { RenderStats.shared.note("no frame"); return }
        frame.startUpdate()
        frame.endUpdate()
        guard let timing = frame.predictTiming() else { RenderStats.shared.note("no timing"); return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        guard let first = drawables.first else { RenderStats.shared.note("no drawable"); frame.endSubmission(); return }
        // Head pose at presentation time (required to composite).
        let t = first.frameTiming.presentationTime.timeInterval
        let anchor = worldTracking.queryDeviceAnchor(atTimestamp: t)
        // ANGLE (GLES-on-Metal) renders directly into each per-eye compositor color texture.
        // Blue-ish = the ANGLE path is live (vs the Metal red from spike A). status < 0 = which
        // ANGLE stage failed (see SpikeANGLE.h) — reported to the window so we can debug black.
        var status: Int32 = 0
        var sm = -1
        let cmd = queue.makeCommandBuffer()!
        var texs = [MTLTexture]()
        // 1. ANGLE renders into each drawable's texture (on ANGLE's own Metal queue).
        for drawable in drawables {
            if let anchor { drawable.deviceAnchor = anchor }
            let tex0 = drawable.colorTextures[0]
            texs.append(tex0)
            sm = Int(tex0.storageMode.rawValue)   // 0 shared,1 managed,2 private,3 memoryless
            for s in 0..<drawable.views.count {
                status = SpikeANGLE_RenderInto(device, tex0, Int32(s), Int32(s))
            }
        }
        // 2. Fence ANGLE's work and make the present queue WAIT on it — the GPU cross-queue
        //    barrier that CPU glFinish alone couldn't provide.
        SpikeANGLE_MakeSyncEvent()
        SpikeANGLE_WaitOn(cmd)
        // 3. Re-encode on the present queue (loadAction .load preserves ANGLE's pixels) + present.
        for (i, drawable) in drawables.enumerated() {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = texs[i]
            rpd.colorAttachments[0].loadAction = .load        // keep ANGLE's pixels
            rpd.colorAttachments[0].storeAction = .store
            // The compositor uses the drawable's DEPTH texture for reprojection; an unwritten
            // private depth texture has undefined contents and the compositor silently rejects
            // the frame (same failure class as a missing deviceAnchor). Spike A wrote depth and
            // displayed; Spike B never did. Write it. (per Fable's diagnosis)
            rpd.depthAttachment.texture = drawable.depthTextures[0]
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .store
            rpd.rasterizationRateMap = drawable.rasterizationRateMaps.first
            if drawable.views.count > 1 { rpd.renderTargetArrayLength = drawable.views.count }
            let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
            enc.setViewports(drawable.views.map { $0.textureMap.viewport })
            enc.endEncoding()
            drawable.encodePresent(commandBuffer: cmd)
        }
        // Surface present-buffer failures (otherwise a validation kill / wedged wait = silent black).
        cmd.addCompletedHandler { cb in
            if cb.status != .completed { RenderStats.shared.note("cmd status=\(cb.status.rawValue) \(cb.error.map { "\($0)" } ?? "")") }
        }
        cmd.commit()
        frame.endSubmission()
        let err = status < 0 ? String(format: " err=0x%x", SpikeANGLE_LastEGLError()) : ""
        RenderStats.shared.tick("angle=\(status)\(err) rb=\(SpikeANGLE_ReadBack()) sm=\(sm)")
    }
}
