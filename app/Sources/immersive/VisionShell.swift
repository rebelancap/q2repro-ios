// VisionShell.swift — merged visionOS 2D+3D app shell (Q2_XR_UI variant).
// SwiftUI @main hosting the existing UIKit game window (WindowGroup) plus the stereoscopic
// ImmersiveSpace, following the vkQuake-ios blueprint: MIXED immersion (the 3D screen floats
// in passthrough; the 2D window stays beside it for live settings), the engine keeps running
// on the main thread's CADisplayLink in BOTH modes, and the compositor loop is a pure
// consumer that samples the engine's per-eye textures. Enter/exit order is load-bearing:
// engine off the window surface BEFORE the space opens; back on only AFTER dismissal.
import CompositorServices
import SwiftUI
import Metal
import ARKit
import AVFAudio
import UIKit

// Live-tunable stereo settings, UserDefaults-backed (read live by the render paths; the
// engine tick reads xr_sep/xr_conv directly). Defaults per the vkQuake-review round.
enum XR3 {
    static let d = UserDefaults.standard
    static func f(_ k: String, _ def: Float) -> Float { d.object(forKey: k) == nil ? def : d.float(forKey: k) }
    // Defaults per SETTINGS-SPEC-FROM-VKQUAKE.md (the dialed-in vkQuake values).
    static var distance: Float  { f("xr_dist", 3.6) }      // metres in front
    static var halfWidth: Float { f("xr_halfW", 2.75) }    // metres (full width 5.5)
    static var halfHeight: Float { f("xr_halfH", 1.55) }   // metres (full height 3.1) — free shape
    static var height: Float    { f("xr_height", 0.0) }    // metres above eye level (signed)
    static var dim: Float       { f("xr_dim", 0.8) }       // surroundings dimming 0…1 (default 80%)
    static var recenter: Int    { d.integer(forKey: "xr_recenter") }
    static var hideGun: Bool    { d.object(forKey: "xr_hidegun") == nil ? false : d.bool(forKey: "xr_hidegun") }
    static var sharpen: Float   { f("xr_sharpen", 0.5) }   // CAS strength 0…1 (0 = off)
}

// Compositor clock instant → the TimeInterval ARKit's queryDeviceAnchor expects.
extension LayerRenderer.Clock.Instant {
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds / 1_000_000_000) / TimeInterval(NSEC_PER_SEC)
    }
}

final class Q2AppModel: ObservableObject {
    static let shared = Q2AppModel()
    @Published var immersive = false
    @Published var showSettings = false
    // Window size to restore after 3D. Persisted: visionOS remembers the PARKED size as
    // the window's size across relaunches, so if the app dies while parked (backgrounded
    // apps are killed) the next launch opens tiny with nothing in memory to undo it.
    var preParkSize: CGSize {
        didSet {
            UserDefaults.standard.set(Double(preParkSize.width), forKey: "xr_preParkW")
            UserDefaults.standard.set(Double(preParkSize.height), forKey: "xr_preParkH")
        }
    }
    // Explicit park STATE (quake3e's guard) — never re-capture while parked, and never
    // decide "is it parked" from the window's size alone. Persisted so a kill-while-
    // parked launch knows to restore.
    var windowParked: Bool {
        didSet { UserDefaults.standard.set(windowParked, forKey: "xr_windowParked") }
    }
    private init() {
        let d = UserDefaults.standard
        let w = d.double(forKey: "xr_preParkW"), h = d.double(forKey: "xr_preParkH")
        // ≥400x240 sanity: earlier builds persisted a keyWindow mis-capture (the 182x68
        // ornament pill) — restoring to that re-shrank the window forever. Heal it.
        preParkSize = (w >= 400 && h >= 240) ? CGSize(width: w, height: h)
                                             : CGSize(width: 1280, height: 720)
        windowParked = d.bool(forKey: "xr_windowParked")
    }
}

// The parked-card footprint (and the exclusion box used everywhere a size is judged).
// Checks BOTH the requested 480x300 and the size the system ACTUALLY applied to the park
// (learned at park time, persisted) — on device the two can differ (min-size clamping),
// and a mismatch here poisoned the size capture on re-entry.
func q2NearParkSize(_ sz: CGSize) -> Bool {
    if abs(sz.width - 480) < 60 && abs(sz.height - 300) < 60 { return true }
    let d = UserDefaults.standard
    let pw = d.double(forKey: "xr_parkedW"), ph = d.double(forKey: "xr_parkedH")
    return pw > 50 && abs(sz.width - pw) < 60 && abs(sz.height - ph) < 60
}

// The UIKit game window, hosted. Q2_MakeGameViewController (main.m) builds the GameVC +
// GLView and boots the engine exactly like the classic SceneDelegate path did.
struct Q2GameView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { Q2_MakeGameViewController() }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}

private func q2SetAudioFrontStage(_ on: Bool) {
    // Anchor the app's sound stage to the FRONT (at the 3D screen) while immersed, instead
    // of following the parked-aside 2D window; restore automatic on exit. (vkQuake D-029.)
    let session = AVAudioSession.sharedInstance()
    do {
        if on {
            try session.setIntendedSpatialExperience(.headTracked(soundStageSize: .medium, anchoringStrategy: .front))
        } else {
            try session.setIntendedSpatialExperience(.headTracked(soundStageSize: .automatic, anchoringStrategy: .automatic))
        }
    } catch { NSLog("[q2repro] setIntendedSpatialExperience failed: \(error)") }
}

@main
struct Q2VisionApp: App {
    @ObservedObject var model = Q2AppModel.shared
    @Environment(\.openImmersiveSpace) private var openSpace
    @Environment(\.dismissImmersiveSpace) private var dismissSpace
    @Environment(\.scenePhase) private var scenePhase

    // Park the 2D window as a small control card while in 3D (vkQuake UX). visionOS can't
    // move windows programmatically — the user parks the card once; the system remembers.
    private func setWindowSize(_ size: CGSize) {
        // Never request a degenerate size (quake3e's guard) — a bad stored value must
        // not be able to shrink the window below usable.
        guard size.width >= 300, size.height >= 180 else {
            Q2_XR3_Log("xrwin REFUSED degenerate \(Int(size.width))x\(Int(size.height))")
            return
        }
        guard let ws = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.session.role == .windowApplication }) else {
            Q2_XR3_Log("xrwin no window scene for \(Int(size.width))x\(Int(size.height))")
            return
        }
        ws.requestGeometryUpdate(.Vision(size: size)) { error in
            Q2_XR3_Log("xrwin request \(Int(size.width))x\(Int(size.height)) REJECTED \(error.localizedDescription)")
        }
    }
    // The GAME window's real size, nil when not attached. NEVER keyWindow: tapping the
    // ornament pill ("3D"/gear) makes the pill's ~182x68 host window KEY at exactly the
    // moment the entry capture runs — keyWindow-based capture recorded THAT, and the
    // "restore" then faithfully shrank the window to pill size (the device-only
    // stuck-tiny bug; sim entries are env-driven and never tap, so the sim always
    // captured correctly). quake3e reads its game VC's window for the same reason.
    private func actualWindowSize() -> CGSize? {
        let sz = Q2_XR3_GameWindowSize()
        return (sz.width > 1 && sz.height > 1) ? sz : nil
    }
    // Convergent restore. A single requestGeometryUpdate is NOT reliable here: right
    // after dismissImmersiveSpace the window scene can be backgrounded (visionOS drops
    // geometry requests for non-foreground scenes), and after a crown exit with the
    // parked card closed there is briefly NO window scene at all — the one-shot restore
    // silently no-oped in both flows and the window stayed card-sized. Re-request until
    // the window actually leaves the parked footprint (bounded ~6 s).
    private func restoreWindowSize(_ size: CGSize) async {
        Q2_XR3_Log("xrwin restore to \(Int(size.width))x\(Int(size.height))")
        for i in 0..<30 {
            setWindowSize(size)
            try? await Task.sleep(for: .milliseconds(200))
            if let sz = actualWindowSize() {
                if !q2NearParkSize(sz) {
                    Q2_XR3_Log("xrwin restored \(Int(sz.width))x\(Int(sz.height)) attempt \(i + 1)")
                    return
                }
            } else if i % 5 == 4 {
                Q2_XR3_Log("xrwin no key window yet attempt \(i + 1)")
            }
        }
        Q2_XR3_Log("xrwin restore GAVE UP after 30 attempts")
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Q2GameView()
                if model.immersive {
                    // Curtain over the frozen game view while the panel owns rendering.
                    Rectangle().fill(.black.opacity(0.92))
                        .overlay(Text("Playing in 3D").font(.headline).foregroundStyle(.secondary))
                        .ignoresSafeArea()
                }
            }
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                    // Final layout (spec update): bottom pill hanging fully BELOW
                    // the window (contentAlignment .top pins the pill's top to the edge).
                    HStack(spacing: 16) {
                        Button(model.immersive ? "Exit 3D" : "3D") {
                            model.immersive.toggle()
                        }.font(.title3)
                        Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.title3) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassBackgroundEffect()
                }
                .sheet(isPresented: $model.showSettings) { XR3SettingsSheet() }
                .task {
                    // Launch-while-parked rescue: if the app died in 3D, visionOS reopens the
                    // window at the remembered (parked) size and no un-park event may fire.
                    Task {
                        try? await Task.sleep(for: .seconds(3))
                        let stuck = model.windowParked || actualWindowSize().map(q2NearParkSize) == true
                        if !model.immersive, stuck {
                            Q2_XR3_Log("xrwin launched parked (flag \(model.windowParked)) unparking")
                            model.windowParked = false
                            await restoreWindowSize(model.preParkSize)
                        }
                    }
                    // Headless sim validation (taps can't be injected on the visionOS sim):
                    // Q2_XR_AUTOENTER=1 enters 3D after boot; Q2_XR_AUTOEXIT=1 leaves again
                    // later, proving the full 2D→3D→2D round trip. No effect without the env.
                    let env = ProcessInfo.processInfo.environment
                    if let sz = env["Q2_WINDOW_SIZE"] {   // sim validation: force a window size (WxH points)
                        let p = sz.split(separator: "x").compactMap { Double($0) }
                        if p.count == 2 { try? await Task.sleep(for: .seconds(2)); setWindowSize(CGSize(width: p[0], height: p[1])) }
                    }
                    if env["Q2_XR_AUTOENTER"] == "1" {
                        try? await Task.sleep(for: .seconds(12))   // let the engine boot + demo start
                        model.immersive = true
                        if env["Q2_XR_AUTOEXIT"] == "1" {
                            try? await Task.sleep(for: .seconds(25))
                            model.immersive = false
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Forward scene activation to the engine (audio session + display link).
                    // While immersive the aggregate phase stays .active (the space is a scene),
                    // so 3D is never wrongly paused; this fires when the WINDOW is closed and
                    // reopened outside 3D — previously the game came back silent.
                    switch phase {
                    case .active: Q2_XR3_ScenePhase(1)
                    case .background: if !model.immersive { Q2_XR3_ScenePhase(0) }
                    default: break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { _ in
                    // If the user closes the parked card mid-3D the app loses its only regular
                    // scene (audio dies) — bring it back (spec: requestSceneSessionActivation).
                    if model.immersive {
                        UIApplication.shared.requestSceneSessionActivation(nil, userActivity: nil, options: nil, errorHandler: nil)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { _ in
                    // Un-park backstop on PER-SCENE activation (the aggregate scenePhase never
                    // transitions during a 3D exit — the space keeps it .active, so an
                    // onChange-based backstop silently never fired; that was the still-tiny-
                    // after-exit bug's escape hatch failing). Covers relaunch-while-parked and
                    // scenes that reconnect after the exit task's restore window passed.
                    if !model.immersive, model.windowParked || actualWindowSize().map(q2NearParkSize) == true {
                        Q2_XR3_Log("xrwin activated parked (flag \(model.windowParked)) unparking")
                        model.windowParked = false
                        Task { await restoreWindowSize(model.preParkSize) }
                    }
                }
                .onChange(of: model.immersive) { _, on in
                    Task { @MainActor in
                        if on {
                            // Capture the restore size FIRST — before the space opens (a mixed
                            // space can resize the window by the time openSpace returns) — and
                            // ONLY when not parked: an explicit STATE flag, not a size heuristic
                            // (quake3e's guard; heuristics mis-fired and poisoned the capture).
                            // ≥400x240: a real game window is never smaller (the park card is
                            // 480x300); anything below is a mis-read — keep the last good size.
                            if !model.windowParked, let sz = actualWindowSize(),
                               sz.width >= 400, sz.height >= 240 {
                                model.preParkSize = sz
                                Q2_XR3_Log("xrwin captured \(Int(sz.width))x\(Int(sz.height))")
                            } else {
                                Q2_XR3_Log("xrwin capture skipped keeping \(Int(model.preParkSize.width))x\(Int(model.preParkSize.height))")
                            }
                            // Draw-objects don't survive relaunch — re-apply the FPS counter
                            // from the persisted toggle on every 3D entry.
                            if UserDefaults.standard.bool(forKey: "xr_fps") {
                                VID_iOS_Command("undraw cl_fps; draw cl_fps -4 -4")
                            }
                            Q2_XR3_EngineEnter3D()           // offscreen BEFORE the space opens
                            switch await openSpace(id: "q2-3d") {
                            case .opened:
                                q2SetAudioFrontStage(true)
                                // Park the window as a ~480pt card AFTER the space is up
                                // (spec: ~1.5 s; resize is inert to the engine — gated).
                                try? await Task.sleep(for: .seconds(1.5))
                                if model.immersive {
                                    model.windowParked = true
                                    setWindowSize(CGSize(width: 480, height: 300))
                                    Q2_XR3_Log("xrwin parked")
                                }
                            default:
                                Q2_XR3_EngineExit3D()        // roll back — never leave the engine offscreen
                                model.immersive = false
                            }
                        } else {
                            // UN-PARK FIRST, before the space dismissal — quake3e recipe trap c:
                            // never run the resize animation concurrently with the mode
                            // transition. Under mixed immersion the window scene is still
                            // active HERE, so this single request lands reliably; issued after
                            // dismissSpace() it raced the transition and was dropped on device
                            // (the stuck-tiny-window bug — sim transitions are too fast to show it).
                            if model.windowParked {
                                model.windowParked = false
                                setWindowSize(model.preParkSize)
                                Q2_XR3_Log("xrwin unpark to \(Int(model.preParkSize.width))x\(Int(model.preParkSize.height)) before dismiss")
                            }
                            // Stop the render thread and wait for it BEFORE dismissing, so it
                            // never touches a layerRenderer SwiftUI is tearing down (vkQuake's
                            // immStop/immRunning handshake; ≤2 s bound).
                            if let r = Q2PanelRenderer.current {
                                r.stopRequested = true
                                for _ in 0..<200 where r.running { try? await Task.sleep(for: .milliseconds(10)) }
                            }
                            await dismissSpace()
                            q2SetAudioFrontStage(false)
                            Q2_XR3_EngineExit3D()            // back to the window AFTER dismissal
                            // Belt: if the pre-dismiss request still didn't take, the logged
                            // retry loop hammers it until the window leaves the parked footprint.
                            try? await Task.sleep(for: .seconds(1.0))
                            if let sz = actualWindowSize(), q2NearParkSize(sz) {
                                await restoreWindowSize(model.preParkSize)
                            }
                        }
                    }
                }
        }
        .defaultSize(width: 1700, height: 980)   // roomy default game window
        ImmersiveSpace(id: "q2-3d") { Q2ImmersiveContent() }
            // MIXED ONLY: the panel floats in passthrough. Do NOT allow .progressive —
            // merely allowing it changes the drawable contract and encode_present aborts
            // __BUG_IN_CLIENT__ (vkQuake D-029).
            .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}

struct XR3SettingsSheet: View {
    // Stored per SETTINGS-SPEC-FROM-VKQUAKE.md: lengths in meters, depth as percent,
    // dimming 0…1, units toggle (default ft). Sliders apply LIVE (render loop reads
    // UserDefaults every frame; the engine tick reads xr_sep_pct/xr_conv).
    @AppStorage("xr_dist")    private var dist   = 3.6
    @AppStorage("xr_halfW")   private var halfW  = 2.75
    @AppStorage("xr_halfH")   private var halfH  = 1.55
    @AppStorage("xr_height")  private var posH   = 0.0
    @AppStorage("xr_sep_pct") private var sepPct = 100.0
    @AppStorage("xr_conv")    private var conv   = 240.0
    @AppStorage("xr_dim")     private var dim    = 0.8
    @AppStorage("xr_quality") private var quality = 0.6   // device-measured: locked 120/120 at 60%
    @AppStorage("xr_sharpen") private var sharpen = 0.5
    @AppStorage("xr_hidegun") private var hideGun = false
    @AppStorage("xr_fps")     private var fpsOn  = false
    @AppStorage("xr_unitsFt") private var unitsFt = true
    @AppStorage("xr_recenter") private var recenter = 0
    @Environment(\.dismiss) private var dismiss

    private func len(_ m: Double, signed: Bool = false) -> String {
        let v = unitsFt ? m * 3.28084 : m
        let u = unitsFt ? "ft" : "m"
        return signed ? String(format: "%+.1f %@", v, u) : String(format: "%.1f %@", v, u)
    }
    @ViewBuilder private func row(_ label: String, _ v: Binding<Double>,
                                  _ range: ClosedRange<Double>, _ text: String,
                                  resync: Bool = false) -> some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            Slider(value: v, in: range) { editing in
                // Width/Height re-sync the render target to the new panel aspect on RELEASE
                // (drag = quad stretches for instant feedback; release = sharp at the new
                // aspect — vkQuake's mechanic). Ultra-widescreen renders true Hor+.
                if resync && !editing { VID_iOS_XR3_ResizeEyes() }
            }
            Text(text).frame(width: 84, alignment: .trailing)
                .font(.system(.caption, design: .monospaced))
        }
    }
    @ViewBuilder private func info(_ label: String, _ value: String) -> some View {
        HStack { Text(label).frame(width: 190, alignment: .leading); Spacer()
                 Text(value).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary) }
    }
    var body: some View {
        // Spec traps: no forced HEIGHT on sheet content (SwiftUI center-clips), own header
        // bar with a prominent Done (hosted nav bars / safeAreaInset bury controls).
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("VISION PRO 3D").font(.caption.bold()).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {   // 3D keys only; units + FPS prefs kept (spec)
                            dist = 3.6; halfW = 2.75; halfH = 1.55; posH = 0
                            sepPct = 100; conv = 240; dim = 0.8; hideGun = false
                            quality = 1.0
                            VID_iOS_XR3_ResizeEyes()   // apply the restored aspect/budget now
                        }.buttonStyle(.bordered).tint(.orange).font(.caption)
                    }.padding(.top, 8)
                    row("Screen Distance", $dist, 1.0...8.0, len(dist))
                    row("Screen Width", $halfW, 0.6...4.0, len(halfW * 2), resync: true)   // stored half, shown full
                    row("Screen Height", $halfH, 0.5...3.0, len(halfH * 2), resync: true)
                    row("Screen Position Height", $posH, -1.5...10.0, len(posH, signed: true))
                    row("Stereo Depth", $sepPct, 0...320, String(format: "%.0f%%", sepPct))
                    row("Crosshair Distance", $conv, 32...512, len(conv * 0.0254))  // 1 unit ≈ 1 inch
                    row("Surroundings Dimming", $dim, 0...1, String(format: "%.0f%%", dim * 100))
                    // Per-eye render budget as a % of the 8.3 MP vkQuake formula. Q2
                    // rerelease frames through ANGLE are much heavier than Q1 Vulkan —
                    // lower this if 3D feels laggy (FOVEATION-PERF-CONSULT.md).
                    row("Render Resolution", $quality, 0.4...1.0,
                        String(format: "%.0f%%", quality * 100), resync: true)
                    // CAS strength: the upscale companion to a reduced budget — restores
                    // perceived edge crispness the panel's slight magnification softens.
                    // Applies live (read per published engine frame).
                    row("Sharpening", $sharpen, 0...1, String(format: "%.0f%%", sharpen * 100))
                    Text("These two work together: lower resolution keeps 3D fast and smooth, Sharpening restores the crispness. 60% + 100% is the sweet spot.")
                        .font(.caption2).foregroundStyle(.secondary)
                    let aspect = max(0.5, min(4.0, halfW / max(halfH, 0.01)))
                    let pw = Int((Double(3840 * 2160) * max(0.4, min(1.0, quality)) * aspect).squareRoot().rounded())
                    info("Panel Width", "\(pw & ~7) px")
                    info("Panel Height", "\((Int((Double(pw) / aspect).rounded())) & ~7) px")
                    info("Aspect Ratio", String(format: "%.1f:9", aspect * 9))
                    Toggle("Hide weapon", isOn: $hideGun)
                    Toggle("FPS on Panel", isOn: $fpsOn)
                        .onChange(of: fpsOn) { _, on in
                            // Q2PRO has no scr_fps cvar; fps is a draw-object ("draw cl_fps x y",
                            // negative coords anchor right/bottom). It lands in the 2D pass, which
                            // renders into BOTH eye textures — visible on the panel and in 2D.
                            VID_iOS_Command(on ? "undraw cl_fps; draw cl_fps -4 -4" : "undraw cl_fps")
                        }
                    HStack {
                        Text("Units").frame(width: 190, alignment: .leading)
                        Picker("", selection: $unitsFt) {
                            Text("m").tag(false); Text("ft").tag(true)
                        }.pickerStyle(.segmented).frame(width: 160)
                        Spacer()
                    }
                    Button("Recenter Screen") { recenter += 1 }.buttonStyle(.bordered)
                        .padding(.top, 4)
                }.padding(.horizontal, 24).padding(.bottom, 20)
            }
        }
        .frame(minWidth: 900)   // width ONLY (forced height center-clips — spec trap)
    }
}

// ================================ immersive consumer =================================

struct Q2XRConfig: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // Negotiate formats like vkQuake/quake3e/SoH instead of hardcoding rgba16Float:
        // the system's preferred format is 8-bit sRGB — HALF the drawable bandwidth of
        // float16 in our pass and in the system's foveated unwarp, on the GPU the engine
        // is already saturating (FOVEATION-PERF-CONSULT.md). The panel shader outputs
        // linear either way; an sRGB store re-encodes in hardware.
        configuration.depthFormat = capabilities.supportedDepthFormats.first ?? .depth32Float
        configuration.colorFormat = capabilities.supportedColorFormats.first ?? .bgra8Unorm_srgb
        // Eye-tracked foveation de-blurs the panel (VISIONOS-FOVEATION-GUIDE.md): the
        // drawable becomes gaze-tracked variable-density, so effective foveal resolution
        // multiplies. The old "foveation off" was a vkQuake Vulkan-era constraint that
        // never applied to this native-Metal pass. Sim reports supportsFoveation false.
        // Always on when the hardware supports it — the A/B toggle is retired (off is
        // just blurry; and a persisted "off" would strand the user blurry with no UI).
        // The stored xr_foveation key is deliberately IGNORED.
        let fov = capabilities.supportsFoveation
        configuration.isFoveationEnabled = fov
        let layouts = capabilities.supportedLayouts(options: [])
        // TRAP (guide #1): layered layout + per-slice passes + foveation = right-eye
        // fisheye (each pass rasterizes with layer 0's rate map). Dedicated layout gives
        // per-eye textures AND per-eye rate maps. Do NOT touch maxRenderQuality (trap #2:
        // aborts at immersive entry).
        if fov && layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else {
            configuration.layout = layouts.contains(.layered) ? .layered : .dedicated
        }
    }
}

struct Q2ImmersiveContent: CompositorContent {
    var body: some CompositorContent {
        CompositorLayer(configuration: Q2XRConfig()) { @MainActor layerRenderer in
            let r = Q2PanelRenderer(layerRenderer)
            let t = Thread { r.run() }
            t.name = "q2-immersive"; t.stackSize = 2 << 20
            t.start()
        }
    }
}

private func translation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    var m = matrix_identity_float4x4; m.columns.3 = SIMD4<Float>(x, y, z, 1); return m
}

// Pure consumer: waits on the engine's shared-event fence, samples the two eye textures the
// engine (main thread, ANGLE) rendered, and draws them on a world-locked stereo panel with
// alpha-0 clear (passthrough shows around it) and linearizing sample (engine output is
// display-encoded; the drawable is linear float16).
final class Q2PanelRenderer {
    static var current: Q2PanelRenderer?      // for the exit handshake
    let lock = NSLock()
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
    let arSession = ARKitSession()
    let worldTracking = WorldTrackingProvider()
    var pipeline: MTLRenderPipelineState?
    var dimPipeline: MTLRenderPipelineState?
    var casPipeline: MTLComputePipelineState?   // contrast-adaptive sharpen (upscale companion)
    var depthState: MTLDepthStencilState?
    var copyTex: [MTLTexture] = []   // compositor-owned mipmapped copies of the eye images
    var frozenHead: simd_float4x4?
    var frames = 0
    var lastRecenter = XR3.recenter
    // Pacing telemetry (once per ~5 s into console.log): published engine fps vs the
    // compositor's, and the in-flight depth — the numbers that judge the producer bound.
    var statPub: Int32 = 0
    var statTime = CFAbsoluteTimeGetCurrent()

    init(_ layer: LayerRenderer) {
        self.layer = layer
        self.device = layer.device
        self.queue = device.makeCommandQueue()!
        Task { try? await self.arSession.run([self.worldTracking]) }
        // Pipelines are built lazily from the FIRST drawable's actual formats (quake3e/
        // SoH pattern) — the config now negotiates formats instead of hardcoding them.
    }

    // The GLUE owns a ring of eye textures and publishes a pair only when its GPU frame
    // completes (SoH producer architecture). Fetch the published pair EVERY frame — the
    // pointer cycles through the ring textures.
    var lastEyeGen: Int32 = -1
    var lastBlitFrame: Int32 = -1     // publish count last copied into copyTex
    private func publishedEyeTextures() -> [MTLTexture]? {
        let gen = VID_iOS_XR3_EyeGeneration()
        if gen != lastEyeGen { copyTex = []; lastEyeGen = gen; lastBlitFrame = -1 }   // recreated (aspect re-sync)
        guard let a = VID_iOS_XR3_EyeTexture(0), let b = VID_iOS_XR3_EyeTexture(1) else { return nil }
        return [Unmanaged<AnyObject>.fromOpaque(a).takeUnretainedValue() as! MTLTexture,
                Unmanaged<AnyObject>.fromOpaque(b).takeUnretainedValue() as! MTLTexture]
    }
    // Compositor-owned mipmapped private copies (the engine textures carry no mips):
    // copy + mipgen + sample all stay coherent on this queue, fully decoupled from the
    // engine's. Recreated when the eye size changes.
    private func ensureCopies(like src: MTLTexture) {
        if copyTex.count == 2, copyTex[0].width == src.width, copyTex[0].height == src.height { return }
        lastBlitFrame = -1                        // fresh copies must be filled
        copyTex = (0..<2).compactMap { _ in
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat,
                                                              width: src.width, height: src.height,
                                                              mipmapped: true)
            td.usage = [.shaderRead, .shaderWrite, .renderTarget]   // write: CAS; renderTarget: mipgen
            td.storageMode = .private
            return device.makeTexture(descriptor: td)
        }
    }

    private func buildPipeline(color: MTLPixelFormat, depth: MTLPixelFormat) {
        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv;
                      uint layer [[render_target_array_index]]; uint vp [[viewport_array_index]]; };
        vertex VOut q2vtx(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]],
                          constant uint& eye [[buffer(1)]]) {
            const float2 p[4]  = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
            // GL renders bottom-up: the quad's BOTTOM vertices sample v=0 (the image bottom).
            // (The upside-down bug: this table had v flipped — validated on a solid clear,
            // which can't show orientation.)
            const float2 uv[4] = { float2(0,0),   float2(1,0),  float2(0,1),  float2(1,1) };
            VOut o; o.pos = mvp * float4(p[vid], 0, 1); o.uv = uv[vid]; o.layer = eye; o.vp = eye; return o;
        }
        // Surroundings dimming: a fullscreen black triangle drawn UNDER the panel, alpha =
        // perceptual dim level. Far depth so compositor reprojection treats it as distant.
        struct DOut { float4 pos [[position]]; uint layer [[render_target_array_index]]; uint vp [[viewport_array_index]]; };
        vertex DOut q2dimvtx(uint vid [[vertex_id]], constant uint& eye [[buffer(1)]]) {
            const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };
            DOut o; o.pos = float4(p[vid], 0.9999, 1); o.layer = eye; o.vp = eye; return o;
        }
        fragment float4 q2dimfrag(DOut in [[stage_in]], constant float& a [[buffer(0)]]) {
            return float4(0, 0, 0, a);
        }
        fragment float4 q2frag(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            // max_anisotropy(16): the panel is strongly minified and oblique at its
            // corners — without anisotropy the edges shimmer under motion (SoH parity).
            constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge,
                                max_anisotropy(16));
            float4 c = tex.sample(s, in.uv);
            c.rgb = pow(max(c.rgb, float3(0.0)), 2.2);   // display-encoded → linear drawable
            return float4(c.rgb, 1.0);
        }
        // Contrast-adaptive sharpening (CAS): runs ONCE per published engine frame at
        // texture resolution into the copy's level 0 (the mip chain then propagates it).
        // This is the "render at 60%, look near-100%" upscale companion: the panel
        // magnifies the reduced-budget render slightly, and CAS restores the perceived
        // edge crispness that bilinear magnification softens.
        kernel void q2cas(texture2d<float, access::read> srcT [[texture(0)]],
                          texture2d<float, access::write> dstT [[texture(1)]],
                          constant float& strength [[buffer(0)]],
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
            pd.vertexFunction = lib.makeFunction(name: "q2vtx")
            pd.fragmentFunction = lib.makeFunction(name: "q2frag")
            pd.colorAttachments[0].pixelFormat = color
            pd.depthAttachmentPixelFormat = depth
            pd.inputPrimitiveTopology = .triangle
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
            let dp = MTLRenderPipelineDescriptor()
            dp.vertexFunction = lib.makeFunction(name: "q2dimvtx")
            dp.fragmentFunction = lib.makeFunction(name: "q2dimfrag")
            dp.colorAttachments[0].pixelFormat = color
            dp.colorAttachments[0].isBlendingEnabled = true
            dp.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            dp.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            dp.colorAttachments[0].sourceAlphaBlendFactor = .one
            dp.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            dp.depthAttachmentPixelFormat = depth
            dp.inputPrimitiveTopology = .triangle
            dimPipeline = try device.makeRenderPipelineState(descriptor: dp)
            let dsd = MTLDepthStencilDescriptor()
            dsd.depthCompareFunction = .always         // only the panel draws…
            dsd.isDepthWriteEnabled = true             // …but write REAL depth for reprojection
            depthState = device.makeDepthStencilState(descriptor: dsd)
            if let casFn = lib.makeFunction(name: "q2cas") {
                casPipeline = try? device.makeComputePipelineState(function: casFn)
            }
        } catch { NSLog("[q2repro] panel pipeline: \(error)") }
    }

    func run() {
        running = true
        Q2PanelRenderer.current = self
        defer { running = false; Q2PanelRenderer.current = nil }
        while !stopRequested {
            switch layer.state {
            case .paused: layer.waitUntilRunning()
            case .running: autoreleasepool { frame() }
            case .invalidated:
                // Digital Crown / system dismissal: reconcile the SwiftUI state so the
                // engine returns to the window and the button reads "3D" again.
                DispatchQueue.main.async {
                    if Q2AppModel.shared.immersive {
                        Q2AppModel.shared.immersive = false   // triggers dismiss+exit path
                    }
                }
                return
            @unknown default: return
            }
        }
    }

    // vkQuake's panel placement: level, facing the (frozen) head; raising it auto-tilts
    // toward the viewer because the normal keeps pointing at the head.
    private func panelModel(head: simd_float4x4) -> simd_float4x4 {
        let headPos = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        var fwd = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
        fwd.y = 0
        if simd_length(fwd) < 0.001 { fwd = SIMD3<Float>(0, 0, -1) }
        fwd = simd_normalize(fwd)
        var pos = headPos + fwd * XR3.distance
        pos.y += XR3.height
        var normal = simd_normalize(headPos - pos)
        var up = SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(up, normal))
        up = simd_cross(normal, right)
        let halfW = XR3.halfWidth
        let halfH = XR3.halfHeight
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4<Float>(right * halfW, 0)
        m.columns.1 = SIMD4<Float>(up * halfH, 0)
        m.columns.2 = SIMD4<Float>(normal, 0)
        m.columns.3 = SIMD4<Float>(pos, 1)
        return m
    }

    private func frame() {
        // vkQuake's proven sequence under MIXED immersion (stricter contract than .full):
        // predict timing → update phase → wait for optimal input → submission phase →
        // query drawable → anchor → encode → present → commit → end submission.
        guard let frame = layer.queryNextFrame() else { return }
        guard let timing = frame.predictTiming() else { return }
        frame.startUpdate(); frame.endUpdate()
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)
        frame.startSubmission()
        let drawables = frame.queryDrawables()
        // A failed queryDrawables (empty — happens while the space is being dismissed)
        // INVALIDATES the frame: calling endSubmission on it aborts __BUG_IN_CLIENT__
        // ("failures from cp_frame_query_drawables properly handled?"). Just return.
        guard let drawable = drawables.first else { return }
        // Pipelines from the FIRST drawable's actual (negotiated) formats.
        if pipeline == nil, let c0 = drawable.colorTextures.first, let d0 = drawable.depthTextures.first {
            buildPipeline(color: c0.pixelFormat, depth: d0.pixelFormat)
            // One-shot diagnostics for the device round: drawable geometry + foveation
            // state land in console.log (FOVEATION-PERF-CONSULT.md wants these numbers).
            let vp = drawable.views[0].textureMap.viewport
            Q2_XR3_Log("xr3diag drawable \(c0.width)x\(c0.height) fmt \(c0.pixelFormat.rawValue) " +
                       "texs \(drawable.colorTextures.count) views \(drawable.views.count) " +
                       "rateMaps \(drawable.rasterizationRateMaps.count) vp \(Int(vp.width))x\(Int(vp.height))")
        }
        let published = publishedEyeTextures()   // GPU-complete pair, or nil before first frame
        guard let pipeline, let depthState else { frame.endSubmission(); return }
        let t = drawable.frameTiming.presentationTime.timeInterval
        if let a = worldTracking.queryDeviceAnchor(atTimestamp: t) { drawable.deviceAnchor = a }

        frames += 1
        if frames % 450 == 0 {   // ~5 s at 90 Hz
            let now = CFAbsoluteTimeGetCurrent()
            let pub = VID_iOS_XR3_FramesRendered()
            let dt = now - statTime
            if dt > 0.5, pub >= statPub {
                let efps = Double(pub - statPub) / dt
                Q2_XR3_Log(String(format: "xr3stat engine %.1f fps published, compositor %.1f fps, inFlight %d",
                                  efps, 450.0 / dt, VID_iOS_XR3_InFlight()))
            }
            statPub = pub; statTime = now
        }
        let rc = XR3.recenter
        if rc != lastRecenter { lastRecenter = rc; frozenHead = nil; frames = 0 }
        if frozenHead == nil, frames > 30, let a = drawable.deviceAnchor {
            frozenHead = a.originFromAnchorTransform
        }
        let head = frozenHead ?? (drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4)
        let model = panelModel(head: head)
        let worldFromDevice = drawable.deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        let cmd = queue.makeCommandBuffer()!
        // No cross-queue fence: `published` is only ever a pair whose engine GPU work
        // already completed. Copy it into our own mipmapped textures and rebuild the
        // chains — minified panel content samples clean instead of shimmering.
        // ONLY when a NEW pair has been published (quake3e's gate): the compositor runs
        // ~90 Hz and the engine slower — re-copying an unchanged pair burned ~2×8 MP of
        // blit+mipgen bandwidth per frame for nothing, on the GPU the engine needs.
        if let pub = published {
            ensureCopies(like: pub[0])
            let pubCount = VID_iOS_XR3_FramesRendered()
            if copyTex.count == 2, pubCount != lastBlitFrame {
                var strength = XR3.sharpen
                if let cas = casPipeline, strength > 0.01, let ce = cmd.makeComputeCommandEncoder() {
                    // CAS pass replaces the plain copy: published → sharpened copy L0.
                    ce.setComputePipelineState(cas)
                    for e in 0..<2 {
                        ce.setTexture(pub[e], index: 0)
                        ce.setTexture(copyTex[e], index: 1)
                        ce.setBytes(&strength, length: MemoryLayout<Float>.size, index: 0)
                        ce.dispatchThreadgroups(
                            MTLSize(width: (pub[e].width + 7) / 8, height: (pub[e].height + 7) / 8, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                    }
                    ce.endEncoding()
                    if let blit = cmd.makeBlitCommandEncoder() {
                        for e in 0..<2 { blit.generateMipmaps(for: copyTex[e]) }
                        blit.endEncoding()
                    }
                    lastBlitFrame = pubCount
                } else if let blit = cmd.makeBlitCommandEncoder() {
                    for e in 0..<2 {
                        blit.copy(from: pub[e], sourceSlice: 0, sourceLevel: 0,
                                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                                  sourceSize: MTLSize(width: pub[e].width, height: pub[e].height, depth: 1),
                                  to: copyTex[e], destinationSlice: 0, destinationLevel: 0,
                                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                        blit.generateMipmaps(for: copyTex[e])
                    }
                    blit.endEncoding()
                    lastBlitFrame = pubCount
                }
            }
        }
        // Draw the game only once a completed stereo frame has been published — sampling
        // before that showed uninitialized black (first-entry bug).
        let gameReady = published != nil && copyTex.count == 2
        // ONE PASS PER VIEW, targeted through the view's texture map (foveation guide §2):
        // never hardcode texture 0 / slice i. Dedicated layout (foveation on) → per-eye
        // texture + per-eye rate map; layered (foveation off) → shared texture, per-slice
        // passes. Each pass targets a single slice, so shader layer/viewport routing is 0.
        // Surroundings dimming under the panel: perceptual curve (linear "doesn't get dark
        // until 80%"): alpha = 1 − (1 − d)^2.2. Default 80% ≈ 97% dark.
        let d = max(0, min(1, XR3.dim))
        var dimAlpha = Float(1.0 - pow(Double(1.0 - d), 2.2))
        for (i, view) in drawable.views.enumerated() {
            let tmap = view.textureMap
            let texIdx = min(tmap.textureIndex, drawable.colorTextures.count - 1)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.colorTextures[texIdx]
            rpd.colorAttachments[0].slice = tmap.sliceIndex
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)  // passthrough
            rpd.colorAttachments[0].storeAction = .store
            rpd.depthAttachment.texture = drawable.depthTextures[texIdx]
            rpd.depthAttachment.slice = tmap.sliceIndex
            rpd.depthAttachment.loadAction = .clear
            rpd.depthAttachment.clearDepth = 1.0
            rpd.depthAttachment.storeAction = .store
            if !drawable.rasterizationRateMaps.isEmpty {   // guide §3: nil when foveation off
                rpd.rasterizationRateMap =
                    drawable.rasterizationRateMaps[min(texIdx, drawable.rasterizationRateMaps.count - 1)]
            }
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            enc.setViewport(tmap.viewport)               // guide §4: the view's own viewport
            enc.setDepthStencilState(depthState)
            enc.setCullMode(.none)
            var route = UInt32(0)   // single-slice pass: layer/viewport index is always 0
            if let dimPipeline, dimAlpha > 0.003 {
                enc.setRenderPipelineState(dimPipeline)
                enc.setVertexBytes(&route, length: MemoryLayout<UInt32>.size, index: 1)
                enc.setFragmentBytes(&dimAlpha, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            if gameReady {
                enc.setRenderPipelineState(pipeline)
                let worldFromEye = worldFromDevice * view.transform
                // Under MIXED immersion cp_view_get_tangents aborts __BUG_IN_CLIENT__ (it
                // belongs to the full-immersion contract); use the drawable's projection.
                let proj = drawable.computeProjection(convention: .rightUpBack, viewIndex: i)
                var mvp = proj * worldFromEye.inverse * model
                enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.size, index: 0)
                enc.setVertexBytes(&route, length: MemoryLayout<UInt32>.size, index: 1)
                enc.setFragmentTexture(copyTex[min(i, 1)], index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            enc.endEncoding()
        }
        drawable.encodePresent(commandBuffer: cmd)
        cmd.commit()
        frame.endSubmission()
    }

    private func q2Projection(_ t: SIMD4<Float>, near n: Float = 0.05, far f: Float = 100) -> simd_float4x4 {
        let l = t.x, r = t.y, tp = t.z, b = t.w
        return simd_float4x4(
            SIMD4<Float>(2 / (l + r), 0, 0, 0),
            SIMD4<Float>(0, 2 / (tp + b), 0, 0),
            SIMD4<Float>((r - l) / (l + r), (tp - b) / (tp + b), f / (n - f), -1),
            SIMD4<Float>(0, 0, f * n / (n - f), 0))
    }
    private func q2Projection(_ t: SIMD4<Float>) -> simd_float4x4 { q2Projection(t, near: 0.05, far: 100) }
}
