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
    // [R21] THE VR MENU/DEMO PANEL's angular width, in degrees across. Read here rather than
    // through a C accessor because this enum is already the live UserDefaults seam the
    // compositor reads every frame (distance/height/dim/sharpen all come through it), and the
    // panel quad is built on the compositor side. Clamped to the row's range so a stale or
    // hand-written store can never produce a panel that is a slit or wraps past the eye's
    // ~94-degree horizontal field.
    static var panelDegrees: Float { max(40, min(90, f("vr_panelsize", 64))) }
}

// Compositor clock instant → the TimeInterval ARKit's queryDeviceAnchor expects.
extension LayerRenderer.Clock.Instant {
    var timeInterval: TimeInterval {
        let c = LayerRenderer.Clock.Instant.epoch.duration(to: self).components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds / 1_000_000_000) / TimeInterval(NSEC_PER_SEC)
    }
}

// Three modes, not a bool. visionOS allows exactly ONE immersive space open at a time and
// fixes a space's immersion style at compile time, so the panel (.mixed — the screen floats
// in the room) and VR (.full) are two DIFFERENT spaces and a direct panel<->VR switch is
// sequenced dismiss-then-open with the engine running throughout. Trying to switch styles
// on one space is the shape that does not work.
enum Q2Mode: Int { case flat = 0, panel = 1, vr = 2 }

final class Q2AppModel: ObservableObject {
    static let shared = Q2AppModel()
    @Published var mode: Q2Mode = .flat
    // Set while a rollback writes `mode` from inside the transition handler, so a failed
    // entry does not re-enter the handler it is unwinding.
    var suppressTransition = false
    // The mode the machine has actually FINISHED applying, and whether a transition is in
    // flight. `mode` is the request; this pair is the truth. Both are needed because
    // SwiftUI delivered the same onChange twice (two window scenes install the modifier
    // twice), and the duplicate opened a second immersive space over the first — which
    // fails, and whose rollback then tore down the entry that had just succeeded. A
    // transition machine driven only by "what changed" cannot tell that apart from a real
    // second request.
    var appliedMode: Q2Mode = .flat
    var applying = false
    // Derived, deliberately not published: every existing reader means "is an immersive
    // space open", and making it a second source of truth is how a tri-state rots back
    // into two disagreeing bools.
    var immersive: Bool { mode != .flat }
    // [R7a item 4] THE CURTAIN, as its own state and not as a function of `mode`.
    //
    // `mode` is the REQUEST, written synchronously by the ornament button before the
    // transition machine has done anything. Deriving the curtain from it meant the curtain
    // dropped the instant the player tapped "Exit VR" — and then the whole teardown (render
    // thread stop up to 2 s, engine thread stop up to 2 s, dismissal, the finalize) ran with
    // the frozen entry frame back on display. It is now raised and lowered by applyMode, at
    // the two moments the machine actually knows the answer. The donors' L-6, which cost
    // quake3e a device round: a request is not an outcome, so log the outcome.
    @Published var curtain: Bool = false
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
    //
    // The call itself lives in ios_audio.m, which STORES the desired mode and re-asserts it
    // at the end of every Q2_iOS_AudioApply(). Apply runs from six places (driver init,
    // foreground re-activate, four notification observers, the 4 Hz drift poll, the settings
    // picker) and in STOP_OTHERS mode also bounces setActive — any of which could drop a
    // spatial experience set once from here. SHELL-GAPS item 11.
    Q2_iOS_SetSpatialMode(on ? 1 : 0)   // 1 = front, 0 = automatic (2 = bypassed, for VR)
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

    // ================================ mode machine ====================================
    // ONE place that owns every transition, because the alternative is N scattered "and
    // also set…" lines that rot apart the first time two transitions race. Order is
    // load-bearing throughout and each step says why.
    //
    // Exit ordering (guide §5 rule 3): stop the render thread and WAIT for it, then dismiss
    // the space, then reset engine mode in the completion. Any other order wedges.
    //
    // Window geometry animations and render-target restarts must not overlap (rule 2), so
    // the window is parked 1.5 s AFTER entry settles and un-parked BEFORE the dismissal.

    // ONE transition at a time, and it works from `appliedMode` (what is true) towards
    // `mode` (what is asked), re-checking at the end. A duplicate request for the mode we
    // already reached is therefore a no-op instead of a second openImmersiveSpace, and a
    // mode changed mid-transition is honoured on the next lap instead of being lost.
    @MainActor private func applyMode() async {
        guard !model.applying else { return }
        model.applying = true
        defer { model.applying = false }
        var laps = 0
        while model.appliedMode != model.mode && laps < 8 {
            laps += 1
            let old = model.appliedMode, new = model.mode
            Q2_XR3_Log("MODE request \(old.rawValue) -> \(new.rawValue)")
            // [R7a item 4] Up BEFORE anything that stops the window rendering, down only
            // after the machine has settled back on flat — so the curtain covers the whole
            // of every teardown, including a rollback and a direct VR<->3D switch.
            if new != .flat { setCurtain(true) }
            if old != .flat { await leaveSpace(old, goingTo: new) }
            model.appliedMode = .flat
            if new != .flat {
                // A direct panel<->VR switch is a dismiss followed by an open, and visionOS
                // needs the first to have actually finished. The engine keeps running
                // across the gap; only the presentation surface changes.
                if old != .flat { try? await Task.sleep(for: .seconds(1.0)) }
                model.appliedMode = await enterSpace(new) ? new : .flat
            }
        }
        if model.appliedMode == .flat { setCurtain(false) }
    }

    // One writer, and it reports the OUTCOME rather than the request — the line a device log
    // needs to distinguish "the curtain was asked for" from "the curtain is up".
    @MainActor private func setCurtain(_ up: Bool) {
        if model.curtain == up { return }
        model.curtain = up
        // [R23] The entry watch reports the curtain as an OUTCOME beside the compositor's own
        // counters, so a "black screen" report can be told apart from "the 2D window is
        // covered" without asking the player to distinguish them.
        Q2_VR_NoteCurtain(up ? 1 : 0)
        Q2_XR3_Log("xrwin curtain: \(up ? "UP" : "DOWN")")
    }

    @MainActor private func enterSpace(_ mode: Q2Mode) async -> Bool {
        // Capture the restore size FIRST — before the space opens — and ONLY when not
        // parked: an explicit STATE flag, not a size heuristic (heuristics mis-fired and
        // poisoned the capture). ≥400x240: a real game window is never smaller than the
        // 480x300 park card, so anything below is a mis-read; keep the last good size.
        if !model.windowParked, let sz = actualWindowSize(), sz.width >= 400, sz.height >= 240 {
            model.preParkSize = sz
            Q2_XR3_Log("xrwin captured \(Int(sz.width))x\(Int(sz.height))")
        } else {
            Q2_XR3_Log("xrwin capture skipped keeping \(Int(model.preParkSize.width))x\(Int(model.preParkSize.height))")
        }
        // Draw-objects don't survive relaunch — re-apply the FPS counter on every entry.
        // [R21] Two rows, one draw-object: the 3D panel's "FPS on Panel" (xr_fps, bottom-right
        // of the panel) and VR's "FPS Counter" (vr_fps, top-right of the HUD quad). `draw`
        // keyed by cvar UPDATES an existing object's position rather than adding a second one,
        // so whichever mode is being entered decides where the one object sits — and the mode
        // whose row is off gets it undrawn instead.
        let dfl = UserDefaults.standard
        let wantFps = mode == .vr ? dfl.bool(forKey: "vr_fps") : dfl.bool(forKey: "xr_fps")
        q2SetFpsDraw(wantFps, top: mode == .vr)
        // Asserted, not inferred: the counter reaching the screen depends on a command
        // actually being executed, and the semicolon bug above proved that "the code ran" and
        // "the object exists" are two different claims. The suite anchors on FPSAPPLY and then
        // reads `draw` back.
        Q2_XR3_Log("FPSAPPLY mode=\(mode.rawValue) want=\(wantFps ? 1 : 0) top=\(mode == .vr ? 1 : 0)")
        Q2_iOS_AutoPauseRelease()        // going back in IS a play attempt

        // Engine off the window surface BEFORE the space opens. For VR that also means
        // frame ownership moves to the engine thread BEFORE the space opens: under .full
        // immersion visionOS stops ticking the hidden window's display link, so an engine
        // still driven by that link freezes on the entry frame — one frame of VR forever,
        // a frozen 2D window, and audio that keeps playing because nothing pumps the mixer.
        if mode == .vr { Q2_XR3_EngineEnterVR() } else { Q2_XR3_EngineEnter3D() }

        switch await openSpace(id: mode == .vr ? "q2-vr" : "q2-3d") {
        case .opened:
            // .bypassed for VR: the app's own spatialisation must get out of the way of a
            // world the player is inside. Re-asserted after every Q2_iOS_AudioApply in
            // ios_audio.m, because Apply runs from six places and each could drop it.
            Q2_iOS_SetSpatialMode(mode == .vr ? 2 : 1)
            try? await Task.sleep(for: .seconds(1.5))
            if model.mode == mode {
                model.windowParked = true
                setWindowSize(CGSize(width: 480, height: 300))
                Q2_XR3_Log("xrwin parked")
            }
            return true
        default:
            // Roll back: never leave the engine offscreen with no space to show it. The
            // suppress flag stops this write re-entering the handler it is unwinding.
            Q2_XR3_Log("MODE open FAILED for \(mode.rawValue) - rolling back")
            if mode == .vr { await stopVREngineThread(); Q2_XR3_EngineExitVR() }
            else { Q2_XR3_EngineExit3D() }
            model.suppressTransition = true
            model.mode = .flat
            model.suppressTransition = false
            if model.windowParked {
                model.windowParked = false
                await restoreWindowSize(model.preParkSize)
            }
            return false
        }
    }

    // Bounded poll, never a join: the engine thread can be inside its 20 ms rendezvous wait,
    // and joining from the MainActor would hold main for that long at exactly the moment a
    // dismissal is in flight. Stopping is a request plus a poll.
    @MainActor private func stopVREngineThread() async {
        Q2_XR3_EngineVRStopRequest()
        for _ in 0..<200 where Q2_XR3_EngineVRStopped() == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if Q2_XR3_EngineVRStopped() == 0 {
            Q2_XR3_Log("MODE engine thread did not stop within 2s - finalizing anyway")
        }
    }

    @MainActor private func leaveSpace(_ old: Q2Mode, goingTo new: Q2Mode) async {
        // UN-PARK FIRST, before the dismissal, and only when we are actually going back to
        // the window: never run the resize animation concurrently with a mode transition.
        // Issued after dismissImmersiveSpace it raced the transition and was dropped on
        // device — the stuck-tiny-window bug, which sim transitions are too fast to show.
        if new == .flat, model.windowParked {
            model.windowParked = false
            setWindowSize(model.preParkSize)
            Q2_XR3_Log("xrwin unpark to \(Int(model.preParkSize.width))x\(Int(model.preParkSize.height)) before dismiss")
        }
        if new == .flat {
            // A player yanked out of a space is being shot at by a world they can no longer
            // see. The release is tracked (`pause` is a toggle) and fires on their first
            // input. Then persist NOW: `writeconfig` otherwise runs only when the SCENE
            // backgrounds, and a crown exit does not background the scene — while a system
            // dismissal is frequently the first half of a swipe-kill, and swipe-kill is
            // SIGKILL.
            // NOTE (R2.1) — this write happens while VR still owns the ARCHIVED cvars, so
            // what it puts on disk is the VR override set. That is deliberate and it is
            // safe, but ONLY because of the two things that follow it: the stash is still
            // in NSUserDefaults (so a swipe-kill from here is repaired at the next launch),
            // and Q2_XR3_EngineExitVR below restores the player's values and writes the
            // config AGAIN, synchronously, before clearing the stash. 1.0.11.2 had the
            // restore but not that second write, and every ordinary VR exit persisted
            // "shadows off" into the player's own config. Do not remove either half.
            Q2_iOS_AutoPause()
            Q2_iOS_WriteConfigSync()
            // Both of those go through the producer funnel while the engine thread owns the
            // frame, so they are only queued, not done. Wait for the engine to have actually
            // drained them BEFORE it is asked to stop — otherwise the config write dies with
            // the thread, which is the exact failure the sync write exists to prevent.
            if old == .vr {
                for _ in 0..<50 where Q2_iOS_QueuePending() != 0 {
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
        // Stop the compositor render thread and wait for it BEFORE dismissing, so it never
        // touches a layerRenderer SwiftUI is tearing down.
        if let r = Q2PanelRenderer.current {
            r.stopRequested = true
            for _ in 0..<200 where r.running { try? await Task.sleep(for: .milliseconds(10)) }
        }
        if let r = Q2VRRenderer.current {
            r.stopRequested = true
            for _ in 0..<200 where r.running { try? await Task.sleep(for: .milliseconds(10)) }
        }
        if old == .vr { await stopVREngineThread() }
        await dismissSpace()
        Q2_iOS_SetSpatialMode(0)
        // The finalize restores the stashed cvars AND writes the repaired config inline
        // (the funnel is off by now, so main is the frame thread again and the writeconfig
        // returns with the file on disk). It is the LAST config write of every VR exit, on
        // purpose — see the note above and vr_restore_stash in q2_vr_input.m.
        // [R21] The FPS draw-object belongs to the mode that asked for it: leaving takes it
        // down, and the next entry re-places it from that mode's own row (enterSpace).
        VID_iOS_Command("undraw cl_fps")
        if old == .vr { Q2_XR3_EngineExitVR() } else { Q2_XR3_EngineExit3D() }
        if new == .flat {
            // Belt: if the pre-dismiss request still didn't take, the logged retry loop
            // hammers it until the window leaves the parked footprint.
            try? await Task.sleep(for: .seconds(1.0))
            if let sz = actualWindowSize(), q2NearParkSize(sz) {
                await restoreWindowSize(model.preParkSize)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Q2GameView()
                if model.curtain {
                    // [R7a item 4] Curtain over the frozen game view while a space owns
                    // rendering. The text names the mode the player is ACTUALLY in: a parked
                    // card that read "Playing in 3D" during a VR session was a real report.
                    //
                    // FULLY OPAQUE. It shipped at 0.92, and the 8 % that showed through was
                    // the last presented CAMetalLayer drawable — the exact frame the player
                    // entered on, hanging there for the whole session. The report, in
                    // those words: "a dimmed freeze-frame of the moment of entry". A curtain
                    // that is nearly a curtain is a smear of the thing it is hiding.
                    Rectangle().fill(.black)
                        .overlay(Text(model.mode == .vr ? "Playing in VR" : "Playing in 3D")
                                    .font(.headline).foregroundStyle(.secondary))
                        .ignoresSafeArea()
                }
            }
                .ornament(attachmentAnchor: .scene(.bottom), contentAlignment: .top) {
                    // Final layout (spec update): bottom pill hanging fully BELOW
                    // the window (contentAlignment .top pins the pill's top to the edge).
                    HStack(spacing: 16) {
                        Button(model.mode == .panel ? "Exit 3D" : "3D") {
                            model.mode = (model.mode == .panel) ? .flat : .panel
                        }.font(.title3)
                        Button(model.mode == .vr ? "Exit VR" : "VR") {
                            model.mode = (model.mode == .vr) ? .flat : .vr
                        }.font(.title3)
                        Button { model.showSettings = true } label: { Image(systemName: "gearshape").font(.title3) }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassBackgroundEffect()
                }
                .sheet(isPresented: $model.showSettings) { XR3SettingsSheet() }
                .task {
                    // The stamped VR migration runs at LAUNCH, not only when the sheet is
                    // opened: the engine applies the rows on the generation this bumps, and a
                    // player who enters VR from the ornament without ever opening settings
                    // must still get a migrated store.
                    q2VRMigrateSettings()
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
                    // Q2_XR_SETTINGS=1 opens the settings sheet after boot. Same reason as
                    // AUTOENTER: the visionOS simulator has no way to tap the ornament, so this
                    // is the only way a screenshot can show what the sheet actually contains.
                    if env["Q2_XR_SETTINGS"] == "1" {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(14))
                            model.showSettings = true
                        }
                    }
                    if env["Q2_XR_AUTOENTER"] == "1" || env["Q2_VR_AUTOENTER"] == "1" {
                        try? await Task.sleep(for: .seconds(12))   // let the engine boot + demo start
                        let target: Q2Mode = env["Q2_VR_AUTOENTER"] == "1" ? .vr : .panel
                        model.mode = target
                        // Q2_VR_CYCLES=N: enter/exit N times, which is how the suite asserts
                        // that the third entry is as clean as the first (teardown bugs hide
                        // behind a single round trip).
                        let cycles = Int(env["Q2_VR_CYCLES"] ?? "0") ?? 0
                        if cycles > 0 {
                            for _ in 0..<cycles {
                                try? await Task.sleep(for: .seconds(14))
                                model.mode = .flat
                                try? await Task.sleep(for: .seconds(8))
                                model.mode = target
                            }
                        }
                        if env["Q2_XR_AUTOEXIT"] == "1" {
                            try? await Task.sleep(for: .seconds(25))
                            model.mode = .flat
                        }
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    // Forward scene activation to the engine (audio session + display link).
                    // While immersive the aggregate phase stays .active (the space is a scene),
                    // so 3D is never wrongly paused; this fires when the WINDOW is closed and
                    // reopened outside 3D — previously the game came back silent.
                    //
                    // [R16] BELT AND BRACES: `.active` is now guarded by `!model.immersive`
                    // too. Q2_XR3_ScenePhase(1) unpauses the display link, and in VR the link
                    // is paused because the VR ENGINE THREAD owns Qcommon_Frame and the ANGLE
                    // context — unpausing it puts a second thread into the engine and tears
                    // the refdef (duplicate world, vanishing entities), differently on every
                    // entry because it is a race. The engine-side funnel refuses such an
                    // unpause regardless; this simply stops asking. Audio needs no help here:
                    // the aggregate phase does not leave .active while the space is open.
                    switch phase {
                    case .active: if !model.immersive { Q2_XR3_ScenePhase(1) }
                    case .background: if !model.immersive { Q2_XR3_ScenePhase(0) }
                    default: break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { note in
                    // If the user closes the parked card mid-3D the app loses its only regular
                    // scene (audio dies) — bring it back (spec: requestSceneSessionActivation).
                    //
                    // [R10] But this notification is NOT window-only: it also fires for the
                    // IMMERSIVE SPACE's own scene, and on the Digital Crown path the shell
                    // learns of the exit only afterwards (the layer's .invalidated branch
                    // reconciles the mode), so `model.immersive` is still true when it
                    // arrives. requestSceneSessionActivation(nil, ...) with a nil session
                    // CREATES a scene — that was the empty duplicate window the user had to
                    // close after every Crown exit (1.0.11.12). Our own Exit-VR path flips
                    // the mode to .flat before dismissing, which is why only the Crown showed
                    // it. Two guards, so the intent survives and the duplicate cannot:
                    //   1. act only on a REGULAR window scene's disconnect, never the space's;
                    //   2. act only when no window scene is left — a secondary window closing
                    //      must never conjure a replacement.
                    let scene = note.object as? UIScene
                    let role = scene?.session.role
                    let remaining = UIApplication.shared.connectedScenes.filter {
                        $0.session.role == .windowApplication && $0 !== scene
                    }.count
                    let reactivate = model.immersive && role == .windowApplication && remaining == 0
                    Q2_XR3_Log("xrwin scene disconnect role=\(role?.rawValue ?? "nil") remainingWindows=\(remaining) action=\(reactivate ? "reactivate" : "none")")
                    if reactivate {
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
                .onChange(of: model.mode) { _, _ in
                    guard !model.suppressTransition else { return }
                    Task { @MainActor in await applyMode() }
                }
        }
        .defaultSize(width: 1700, height: 980)   // roomy default game window
        ImmersiveSpace(id: "q2-3d") { Q2ImmersiveContent() }
            // MIXED ONLY: the panel floats in passthrough. Do NOT allow .progressive —
            // merely allowing it changes the drawable contract and encode_present aborts
            // __BUG_IN_CLIENT__ (vkQuake D-029).
            .immersionStyle(selection: .constant(.mixed), in: .mixed)
        // A SECOND space, never a style switch on the first one: the style set is fixed per
        // space at compile time. FULL immersion for VR — mixed was tried and abandoned on a
        // donor because the 2D window never deactivates under it, which breaks "we are back
        // in 2D" detection and leaves the engine rendering to a surface nobody sees.
        ImmersiveSpace(id: "q2-vr") { Q2VRContent() }
            .immersionStyle(selection: .constant(.full), in: .full)
            .upperLimbVisibility(.hidden)
    }
}

// ============================== the settings sheet ===================================
// ONE sheet, SECTIONS rebuilt per open against the mode tri-state (charter D11). The
// visibility rule came from the first headset round, stated verbatim: 2D shows BOTH
// sections, 3D HIDES the VR section, VR HIDES the 3D section. The reason it is a rule and
// not a preference is that a control for a mode you are not in is a control whose effect you
// cannot see, and in a headset that is indistinguishable from a control that does not work.

enum Q2SettingsSection: CaseIterable {
    case threeD, vr
    var title: String { self == .threeD ? "VISION PRO 3D" : "VISION PRO VR" }
    // The short token the dumps carry. Kept beside the title on purpose: the console and the
    // sheet must be naming the same thing, and two tables would let them drift.
    var token: String { self == .threeD ? "3D" : "VR" }
}

// THE RULE ITSELF, in one function, used by the sheet AND reported by SETTINGSNOW. A dump
// that carried its own copy would keep passing after the sheet stopped obeying it.
func q2SettingsSections(for mode: Q2Mode) -> [Q2SettingsSection] {
    switch mode {
    case .flat:  return [.threeD, .vr]   // 2D: both, because either space is one tap away
    case .panel: return [.threeD]        // 3D: the VR section hides
    case .vr:    return [.vr]            // VR: the 3D section hides
    }
}

@_cdecl("Q2_VR_SwiftSettingsSections")
public func Q2_VR_SwiftSettingsSections(_ mode: Int32, _ out: UnsafeMutablePointer<CChar>,
                                        _ cap: Int32) {
    let m = Q2Mode(rawValue: Int(mode)) ?? .flat
    let s = q2SettingsSections(for: m).map(\.token).joined(separator: "+")
    _ = s.withCString { src -> Int in strlcpy(out, src, Int(cap)) }
}

// ---- the VR rows' defaults, in ONE place --------------------------------------------
// vkQuake's play-tested numbers (charter D11). Named here rather than repeated at each
// @AppStorage declaration because Reset, the migration and the declaration must agree, and
// three literals that must agree are two bugs waiting.
enum Q2VRDefaults {
    static let heightTrim = 0.0     // metres, +-0.5, shown in inches
    // R9 — the FOURTH headset verdict on 1.0.11.11: 1.25 was not enough supersampling
    // in the headset. 1.5 is the shipped value; the "above about 1.75x" caption is unchanged.
    static let quality    = 1.5     // multiple of the drawable's PHYSICAL per-view texture
    static let sharpen    = 0.5     // CAS strength on the eye composite
    // [R23] VR ANTI-ALIASING IS NO LONGER A ROW. R20 added it, R21 defaulted it Off after
    // no difference was visible, and R23 removes it outright on the verdict that it
    // "killed FPS": a setting whose only two states are "the default" and "worse" is not a
    // choice, it is a trap with a label. The MSAA BACKEND in xr3_glue stays and is still
    // reachable as `q2vrset vr_msaa N` from the dev console, so the next headset can be
    // measured without resurrecting the code. Stamp 5 force-deletes any stored value.
    static let aimHand    = 1       // 0 = left, 1 = right
    static let moveDir    = 0       // 0 = head, 2 = aim hand, 3 = off hand
    // R9 — SMOOTH BY DEFAULT (fourth verdict). The row is unchanged; only which end of it a
    // player who never opens the sheet lands on has moved. 0 = smooth turning.
    static let snapStep   = 0.0     // degrees; 0 = smooth turning
    static let turnSpeed  = 160.0   // degrees per second, smooth mode (R8: 140 was
                                    // too slow in the headset — third headset verdict)
    static let crosshair  = true
    static let pitchTrim  = 0.0     // degrees, +-15
    static let hudPos     = 1       // 0 = High, 1 = Low, 2 = Off
    // R8 — ROW UNITS, not the engine multiplier. The C side maps row -> engine as
    // 0.8 * row^0.631 (Q2_VR_WeaponSizeToScale, q2_vr_input.m): row 1.0 is the gun that was
    // picked in the headset (old 0.8), row 3.0 is the stated maximum (old 1.6), row 0.5 is
    // about the old minimum. Range 0.5 ... 3.0.
    static let weaponSize = 1.0
    static let haptics    = true
    // R8 — ROW UNITS. R7b shipped 0.75...3.0 with the engine multiplier stored directly, and
    // The verdict on .10 was that the TOP of that slider is where the useful range
    // starts ("the 3.0x should be the MINIMUM"). Rescaled so 1.0 on the row is the old 3.5
    // multiplier: the default reads 1.0x again and the floor (0.85) is just under the old
    // 3.0, which is the minimum he asked for. The CEILING is 2.0, and it takes TWO mechanisms
    // to get there: the engine lays the status bar out as a fixed 320-unit strip centred in a
    // virtual screen of hudrect/autoscale/mul units, so the LAYOUT stops fitting at mul 3.75
    // (row 1.07) and the digits walk off both edges — measured in the R8 sim sweep. So the
    // layout carries the row up to 1.05 and the compositor magnifies the quad's angular
    // extent for the rest (Q2_VR_HudMagnify, ~1.90 at the top). Magnified is softer than
    // re-laid-out, which the caption says out loud.
    // Both conversions live once, in q2_vr_input.m.
    // [R24] The 1.0.11.27 headset verdict moves the default to 1.20: the HUD reads too small at
    // 1.00 in the headset. 1.20 is ABOVE the 1.05 layout cap, so the shipped HUD is now the
    // fully re-laid-out panel (x1.05) plus about 1.14x of quad magnification — slightly softer
    // than 1.00 was, which is the trade the caption already describes.
    static let hudSize    = 1.20    // row units; engine multiplier = min(row, 1.05) x 3.5
    // Metres, ADDED to the High/Low preset's vertical anchor. A continuous raise/lower is
    // what he asked for ("options to raise or lower hud elements"); the picker stays because
    // it also carries Off, and a coarse preset plus a fine trim is the shape every other
    // height control in this sheet already has (see Height / height trim).
    // R9 — the fourth verdict puts the default 40 cm BELOW the preset anchor; the row's
    // range (-0.6...0.6) is unchanged, so the player can still put it back.
    // [R24] ...and the 1.0.11.27 verdict raises it back to -0.20: 40 cm below the anchor put
    // the readout too low once Size and Spread grew the panel. Range unchanged.
    static let hudHeight  = -0.20
    // [R23] HUD SPREAD, and it is a different question from HUD Size. Reported: "is there a way
    // to make the HUD square bigger so that the bottom elements are further from their top
    // elements but without making the hud elements bigger." Size changes how big the health
    // digits ARE; Spread changes how big the CANVAS they are anchored to is, leaving the
    // digits exactly the angular size they were. The engine lays the HUD out in virtual units
    // on a canvas `spread` times wider, and the compositor shows that canvas on a quad
    // `spread` times larger — the two cancel for the elements and compose for the gaps.
    // 1.0 is today's HUD, unchanged, so a player who never touches the row sees no change.
    // Both conversions live once, in q2_vr_input.m (Q2_VR_HudSize / Q2_VR_HudMagnify).
    // [R24] The 1.0.11.27 verdict makes 1.4 the shipped canvas: the gaps that Spread was asked
    // for are what is wanted by default, not an opt-in. Elements stay the angular size Size
    // gives them (the product is invariant in spread), so this is purely more space between
    // the status bar and the messages.
    static let hudSpread  = 1.4     // canvas multiplier, 1.0 ... 2.0
    // R9 — CROSSHAIR SIZE, in multiples of the shipped 1.2-degree cross. The fourth headset
    // verdict asked for the slider by name ("if unsure about the size, give me a slider"),
    // and 1.2 degrees is what the Quake II crosshair he sent as a reference subtends on a
    // 90-degree image. The row is a pure angular multiplier: the reticle keeps the same
    // apparent size at every range (entities.c), so this moves how big it LOOKS and nothing
    // else. It replaces `q2vrdot`'s console-only scale as the source of truth; the command
    // still overrides it for the harness.
    static let crosshairSize = 1.0
    // [R21] THE FPS COUNTER, and it replaces the VR stats overlay. R10's stats block was an
    // instrument with nine numbers on it; what was asked for on 1.0.11.24 is the one number
    // the 2D and 3D modes already show ("just FPS, in the top corner"). It is the engine's own
    // `draw cl_fps` draw-object, not a Swift overlay: in VR the 2D pass is redirected onto the
    // UI texture (overlay 0036/R2), so the same object the panel path uses lands on the HUD
    // quad with no new code on either side. Negative x anchors from the RIGHT and negative y
    // from the BOTTOM (SCR_DrawObjects, screen.c), so `-4 4` is the TOP-right corner.
    static let fps = false
    // [R21] THE MENU/DEMO PANEL's angular width, degrees across. Reported on 1.0.11.24: "the 2D
    // panel during demo/menu in VR mode is too small". 44 was the shipped constant; 64 is the
    // default here, and the row runs 40...90. The panel is 16:9, so at 64 across the half-
    // height is 64/(16/9)/2 = 18 degrees — comfortably inside the eye's ~47 up / 50 down, so
    // the bottom menu row stays in view at the default and at most of the row.
    static let panelSize = 64.0     // degrees across
    // R8 — THE SIX GRIP ROWS ARE GONE. They were a tuning rig with a deadline: they were dialled
    // in the headset on 1.0.11.10 and the answer (-13.0, -7.5, +4.0, 0/0/0) is now the
    // shipped constant in q2_vr_hands.m. Stamp 2 force-deletes their keys. `q2vrgrip` remains
    // as the dev-only rig for the next time the mount changes.
    // Every key the VR section owns, so the migration can talk about "the VR rows" as a set
    // instead of as a list somebody has to remember to extend.
    static let keys = ["vr_heighttrim", "vr_quality", "vr_sharpen", "vr_aimhand", "vr_movedir",
                       "vr_snapstep", "vr_turnspeed", "vr_crosshair", "vr_pitchtrim",
                       "vr_hudpos", "vr_weaponsize", "vr_haptics",
                       "vr_hudsize", "vr_hudheight", "vr_hudspread", "vr_crosshairsize",
                       "vr_fps", "vr_panelsize"]
    // Keys a PAST stamp owned and this one does not. Named here so the migration deletes a
    // set rather than a list somebody has to remember, and so a future row cannot silently
    // inherit a stale value under a name that used to mean something else.
    // [R21] vr_stats joins them: the VR Stats row and its Swift-side overlay are gone (the
    // FPS Counter row is what a player wanted from it), so the key must not sit in the store
    // waiting for a future row to inherit it.
    // [R23] vr_msaa joins them: the Anti-aliasing row is gone (reported: it "killed FPS"), so
    // the key must not sit in the store where the dev-console override would silently inherit
    // a value the player set through a row that no longer exists.
    static let retiredKeys = ["vr_gripfwd", "vr_gripright", "vr_gripup",
                              "vr_grippitch", "vr_gripyaw", "vr_griproll",
                              "vr_stats", "vr_msaa"]
}

// STAMPED MIGRATION (charter D11). The stamp is what makes a later change safe: a row whose
// default moves migrates for players who never touched it (their stored value still equals
// the OLD default) and is left alone for players who did, and a row that is REMOVED has its
// key force-deleted so a future row cannot inherit a stale value under the same name.
//
// Stamp 1 was the section's first appearance: there was nothing to migrate, and the pass
// existed so that the machinery was proven by the same suite case every later stamp uses.
//
// STAMP 2 (R8) is the first real one, and it carries the third headset verdict:
//   * the six vr_grip* rows are RETIRED — force-deleted, unconditionally;
//   * vr_hudsize changes UNIT (new = old / 3.5), because the row is now a multiple of the
//     old 3.5 multiplier rather than the multiplier itself;
//   * vr_weaponsize changes UNIT too, through the inverse of the C side's power map:
//     old = 0.8 * new^0.631  =>  new = (old / 0.8)^(1/0.631) = (old / 0.8)^1.585;
//   * vr_turnspeed's DEFAULT moves 140 -> 160.
//
// STAMP 3 (R9) carries the fourth headset verdict, and it is three DEFAULT moves with
// no unit change at all:
//   * vr_snapstep  30   -> 0     (Snap Turn defaults to Smooth);
//   * vr_hudheight 0.0  -> -0.40 (the HUD sits 40 cm below the preset anchor);
//   * vr_quality   1.25 -> 1.5   (more supersampling).
// HUD Size's default did NOT move (it stays row 1.00), so stamp 3 does not touch it.
// Stamp 3 also ADDS the vr_crosshairsize row. A brand-new key needs no conversion — there is
// no stored value to carry and an absent key already reads as its default — so it appears in
// the keys list and nowhere in the migration body. It is named here so that "stamp 3 is three
// default moves" is not read as "stamp 3 is the only thing R9 changed about the store".
//
// A value that still equals the OLD DEFAULT is a value the player never touched, so it is
// REMOVED rather than converted — that is what lets a default move for everyone who did not
// have an opinion while leaving everyone who did alone. An absent key is already in that
// state and is left absent.
//
// EVERY stamp below the current one runs, in order: a player coming from 1.0.11.10 is at
// stamp 1 and must get stamp 2's unit conversions AND stamp 3's default moves in one launch,
// which is why each block is `if from < N` rather than a switch on `from`.
//
// STAMP 4 (R21) carries the 1.0.11.24 headset verdict, and it is one retirement and one
// default move:
//   * vr_stats is RETIRED — the row and the overlay are gone, so the key is force-deleted
//     (the retiredKeys sweep is re-run here, which also catches a grip key on a store that
//     somehow reached stamp 3 with one still in it: deleting an absent key is free);
//   * vr_msaa's DEFAULT moves 4 -> 0 (Anti-aliasing defaults to Off). Most stores have no
//     stored value at all — @AppStorage writes only when the row is touched — so for them the
//     CODE default is the whole migration, which is why the C side's fallback has to move in
//     the same build. A store that HAS 4 in it gets the untouched-value rule: 4 was the old
//     default, so it is dropped and the new default applies.
//
// STAMP 5 (R23) is one retirement: vr_msaa. The 1.0.11.25 headset verdict on
// Anti-aliasing is "killed FPS", so the ROW is gone; the key is force-deleted by the
// retiredKeys sweep (vr_msaa is now in that list) so that a store carrying a player's old 2x
// or 4x cannot keep charging them for a setting they can no longer see or turn off. The MSAA
// backend itself survives as the dev-console-only `q2vrset vr_msaa N`.
let Q2_VR_SETTINGS_STAMP = 6

// The unit conversions, named so the suite's expectations and this code quote one source.
enum Q2VRStamp2 {
    static let oldHudDefault    = 1.6
    static let oldWeaponDefault = 1.0
    static let oldTurnDefault   = 140.0
    static let hudUnit          = 3.5      // engine multiplier at row 1.0
    // The row's full range. Only the first 1.05 of it is a LAYOUT multiplier; a stored value
    // is a row either way, so the migration clamps to the row's range and not to the cap.
    static let hudRange         = 0.85...2.0
    static let weaponBase       = 0.8
    static let weaponInvExp     = 1.585    // 1 / 0.631
    static let weaponRange      = 0.5...3.0

    static func hudRow(fromOld old: Double) -> Double {
        min(max(old / hudUnit, hudRange.lowerBound), hudRange.upperBound)
    }
    static func weaponRow(fromOld old: Double) -> Double {
        let r = pow(max(old, 0.01) / weaponBase, weaponInvExp)
        return min(max(r, weaponRange.lowerBound), weaponRange.upperBound)
    }
}

// Stamp 3's old defaults, named for the same reason: the migration and the suite's
// expectations should quote one source rather than two agreeing literals.
enum Q2VRStamp3 {
    static let oldSnapDefault    = 30.0    // degrees -> Smooth (0)
    static let oldHudHeightDflt  = 0.0     // metres  -> -0.40
    static let oldQualityDefault = 1.25    // x       -> 1.5
}

// Stamp 4's old default, named for the same reason the two above are.
enum Q2VRStamp4 {
    static let oldMsaaDefault = 4          // 4x MSAA -> Off
}

// Stamp 6's old defaults, named for the same reason every stamp above names its own: the
// migration and the suite's expectations quote one source rather than two agreeing literals.
enum Q2VRStamp6 {
    static let oldHudSizeDflt   = 1.0      // row units -> 1.20
    static let oldHudHeightDflt = -0.40    // metres    -> -0.20
    static let oldHudSpreadDflt = 1.0      // canvas x  -> 1.4
}

@discardableResult
func q2VRMigrateSettings() -> Int {
    let d = UserDefaults.standard
    let from = d.integer(forKey: "vr_migration")
    if from >= Q2_VR_SETTINGS_STAMP { return from }
    var did: [String] = []

    if from < 2 {
        // Rows removed in this stamp are force-deleted, unconditionally: a key left behind is
        // a value a future row inherits under a name that used to mean something else.
        var dropped = 0
        for k in Q2VRDefaults.retiredKeys where d.object(forKey: k) != nil {
            d.removeObject(forKey: k); dropped += 1
        }
        did.append("grip-dropped=\(dropped)")

        // UNIT CHANGES. Untouched (== the old default) or absent means the player had no
        // opinion, so the key is removed and the NEW default applies; anything else is a
        // deliberate choice and is carried across into the new unit.
        if let old = d.object(forKey: "vr_hudsize") as? Double {
            if abs(old - Q2VRStamp2.oldHudDefault) < 0.0005 {
                d.removeObject(forKey: "vr_hudsize"); did.append("hudsize=default")
            } else {
                let v = Q2VRStamp2.hudRow(fromOld: old)
                d.set(v, forKey: "vr_hudsize")
                did.append(String(format: "hudsize=%.2f->%.2f", old, v))
            }
        } else { did.append("hudsize=absent") }

        if let old = d.object(forKey: "vr_weaponsize") as? Double {
            if abs(old - Q2VRStamp2.oldWeaponDefault) < 0.0005 {
                d.removeObject(forKey: "vr_weaponsize"); did.append("weaponsize=default")
            } else {
                let v = Q2VRStamp2.weaponRow(fromOld: old)
                d.set(v, forKey: "vr_weaponsize")
                did.append(String(format: "weaponsize=%.2f->%.2f", old, v))
            }
        } else { did.append("weaponsize=absent") }

        // Turn Speed keeps its unit; only its DEFAULT moved, so the untouched case is the
        // only one that changes.
        if let old = d.object(forKey: "vr_turnspeed") as? Double,
           abs(old - Q2VRStamp2.oldTurnDefault) < 0.5 {
            d.removeObject(forKey: "vr_turnspeed"); did.append("turnspeed=default")
        } else {
            did.append("turnspeed=kept")
        }
    }

    if from < 3 {
        // Three DEFAULTS moved and nothing changed unit, so the whole stamp is the
        // untouched-value rule applied three times: drop a stored value that still equals the
        // old default (the new one then applies), leave anything else exactly as it is.
        for (key, old, eps, label) in [
            ("vr_snapstep",  Q2VRStamp3.oldSnapDefault,    0.5,    "snapstep"),
            ("vr_hudheight", Q2VRStamp3.oldHudHeightDflt,  0.0005, "hudheight"),
            ("vr_quality",   Q2VRStamp3.oldQualityDefault, 0.0005, "quality"),
        ] as [(String, Double, Double, String)] {
            if let stored = d.object(forKey: key) as? Double {
                if abs(stored - old) < eps {
                    d.removeObject(forKey: key); did.append("\(label)=default")
                } else {
                    did.append(String(format: "%@=kept%.2f", label, stored))
                }
            } else {
                did.append("\(label)=absent")
            }
        }
    }

    if from < 4 {
        // The retirement, unconditional — same rule as stamp 2's, re-run because a store that
        // is already at stamp 3 never saw that loop and vr_stats is new to the list.
        var dropped = 0
        for k in Q2VRDefaults.retiredKeys where d.object(forKey: k) != nil {
            d.removeObject(forKey: k); dropped += 1
        }
        did.append("retired-dropped=\(dropped)")

        // Anti-aliasing's default moves 4 -> Off. Untouched (stored 4, the old default) or
        // absent means no opinion, so the key goes and the new default applies; 0 or 2 in the
        // store is a choice and is left exactly as it is.
        if let stored = d.object(forKey: "vr_msaa") as? Int {
            if stored == Q2VRStamp4.oldMsaaDefault {
                d.removeObject(forKey: "vr_msaa"); did.append("msaa=default")
            } else {
                did.append("msaa=kept\(stored)")
            }
        } else {
            did.append("msaa=absent")
        }
    }

    if from < 5 {
        // R23's retirement. Same unconditional rule as stamps 2 and 4, re-run because a store
        // already at stamp 4 never saw that loop and vr_msaa is new to the list. Note this
        // deliberately drops a DELIBERATE 2x/4x too, unlike an untouched-value migration: the
        // row is gone, so a kept value would be an unturnoffable cost.
        var dropped = 0
        for k in Q2VRDefaults.retiredKeys where d.object(forKey: k) != nil {
            d.removeObject(forKey: k); dropped += 1
        }
        did.append("r23-dropped=\(dropped)")
    }

    if from < 6 {
        // R24's three DEFAULT moves. Same shape as stamp 3: drop a stored value that still
        // equals the old default (the new one then applies), leave anything else exactly as
        // it is. Note vr_hudheight moves for the SECOND time — a store that reached stamp 3
        // with the key absent is still absent here, and one that a player set to -0.40 by
        // hand is a deliberate choice this stamp cannot distinguish from stamp 3's untouched
        // case; that is the documented cost of the untouched-value rule and it errs toward
        // giving the player the new default.
        // The labels carry an r24 prefix (stamp 5's "r23-dropped" set the precedent) so that
        // stamp 3's "hudheight=default" and this stamp's cannot be confused in vrmigdid= by a
        // reader or by a suite case: a store coming from stamp 1 emits both.
        for (key, old, eps, label) in [
            ("vr_hudsize",   Q2VRStamp6.oldHudSizeDflt,   0.0005, "r24hudsize"),
            ("vr_hudheight", Q2VRStamp6.oldHudHeightDflt, 0.0005, "r24hudheight"),
            ("vr_hudspread", Q2VRStamp6.oldHudSpreadDflt, 0.0005, "r24hudspread"),
        ] as [(String, Double, Double, String)] {
            if let stored = d.object(forKey: key) as? Double {
                if abs(stored - old) < eps {
                    d.removeObject(forKey: key); did.append("\(label)=default")
                } else {
                    did.append(String(format: "%@=kept%.2f", label, stored))
                }
            } else {
                did.append("\(label)=absent")
            }
        }
    }

    // A BREADCRUMB IN THE STORE, not only in the log. Q2_XR3_Log falls back to NSLog when
    // the engine has not started yet — and at launch it has not — so the VRMIGRATE line below
    // is invisible to the console bridge every suite reads. The same sentence is stored, and
    // VRSETTINGSNOW reports it as vrmigdid=, so what the migration DID is assertable and not
    // merely inferrable from the values it left behind.
    d.set(did.isEmpty ? "nothing" : did.joined(separator: ","), forKey: "vr_migration_did")
    d.set(Q2_VR_SETTINGS_STAMP, forKey: "vr_migration")
    // The generation bump is what makes the engine re-read; it goes LAST, after every value
    // the migration touched is already stored.
    d.set(d.integer(forKey: "vr_gen") + 1, forKey: "vr_gen")
    Q2_XR3_Log("VRMIGRATE from=\(from) to=\(Q2_VR_SETTINGS_STAMP) keys=\(Q2VRDefaults.keys.count) " +
               "did=" + (did.isEmpty ? "nothing" : did.joined(separator: ",")))
    return from
}

// The engine applies the VR rows when this counter moves, and only then (see
// Q2_VR_ApplySettings). Bumped LAST, after the store is complete, so a generation the engine
// observes always describes values that are all already written.
// [R21] ONE COMMAND PER CALL. `VID_iOS_Command` is `Cmd_ExecuteString`, which runs a SINGLE
// command and does NOT split on ';' (the same trap VID_iOS_ToggleMenu documents in
// ios_bridge.m) — so "undraw cl_fps; draw cl_fps -4 4" ran the undraw and silently dropped the
// draw. That is why the FPS counter never appeared on a mode ENTRY, only when a row was
// toggled while the engine was already up... and in fact not then either: every caller used
// the semicolon form. Both callers now go through here, and the counter's position is the one
// thing that differs between them.
//   x < 0 anchors from the RIGHT and y < 0 from the BOTTOM (SCR_DrawObjects, screen.c), so
//   "-4 -4" is bottom-right (the 3D panel) and "-4 4" is TOP-right (VR).
@MainActor func q2SetFpsDraw(_ on: Bool, top: Bool) {
    VID_iOS_Command("undraw cl_fps")
    if on { VID_iOS_Command(top ? "draw cl_fps -4 4" : "draw cl_fps -4 -4") }
}

func q2VRBumpGen() {
    let d = UserDefaults.standard
    d.set(d.integer(forKey: "vr_gen") + 1, forKey: "vr_gen")
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

    // ---- the VR section's own store ----
    @AppStorage("vr_heighttrim") private var vrHeightTrim = Q2VRDefaults.heightTrim
    @AppStorage("vr_quality")    private var vrQuality    = Q2VRDefaults.quality
    @AppStorage("vr_sharpen")    private var vrSharpen    = Q2VRDefaults.sharpen
    @AppStorage("vr_aimhand")    private var vrAimHand    = Q2VRDefaults.aimHand
    @AppStorage("vr_movedir")    private var vrMoveDir    = Q2VRDefaults.moveDir
    @AppStorage("vr_snapstep")   private var vrSnapStep   = Q2VRDefaults.snapStep
    @AppStorage("vr_turnspeed")  private var vrTurnSpeed  = Q2VRDefaults.turnSpeed
    @AppStorage("vr_crosshair")  private var vrCrosshair  = Q2VRDefaults.crosshair
    @AppStorage("vr_pitchtrim")  private var vrPitchTrim  = Q2VRDefaults.pitchTrim
    @AppStorage("vr_hudpos")     private var vrHudPos     = Q2VRDefaults.hudPos
    @AppStorage("vr_weaponsize") private var vrWeaponSize = Q2VRDefaults.weaponSize
    @AppStorage("vr_haptics")    private var vrHaptics    = Q2VRDefaults.haptics
    @AppStorage("vr_hudsize")    private var vrHudSize    = Q2VRDefaults.hudSize
    @AppStorage("vr_hudheight")  private var vrHudHeight  = Q2VRDefaults.hudHeight
    @AppStorage("vr_hudspread")  private var vrHudSpread  = Q2VRDefaults.hudSpread
    @AppStorage("vr_crosshairsize") private var vrCrossSize = Q2VRDefaults.crosshairSize
    @AppStorage("vr_fps")        private var vrFps        = Q2VRDefaults.fps
    @AppStorage("vr_panelsize")  private var vrPanelSize  = Q2VRDefaults.panelSize
    @State private var rconOn = false   // [R10] mirrors the live console state, not a pref

    @ObservedObject private var model = Q2AppModel.shared
    // REBUILT PER OPEN, and stored rather than recomputed in `body`: the sheet must not
    // re-shuffle its sections under the player's finger if the mode changes while it is
    // open (leaving VR from the ornament while the sheet is up is a real sequence).
    @State private var sections: [Q2SettingsSection] = []
    @Environment(\.dismiss) private var dismiss

    private func len(_ m: Double, signed: Bool = false) -> String {
        let v = unitsFt ? m * 3.28084 : m
        let u = unitsFt ? "ft" : "m"
        return signed ? String(format: "%+.1f %@", v, u) : String(format: "%.1f %@", v, u)
    }
    // The height trim is shown in INCHES whatever the Units picker says (charter D7/D11):
    // it is a body measurement, half a metre either way, and feet are the wrong resolution
    // for it. vkQuake shows inches here for the same reason.
    private func inches(_ m: Double) -> String { String(format: "%+.0f in", m * 39.3701) }

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
    // R7b item 11 — THE HEADER PINS. Reported: the section title and its Reset must stay reachable
    // while the section scrolls, because the VR section is now long enough that Reset — the one
    // control a player reaches for when they have made the HUD or the gun unusable — scrolled
    // off before they could see what they had done.
    //
    // Two things make pinning actually work, and both are easy to leave out:
    //   * the header must be OPAQUE. A pinned header floats OVER the rows sliding under it, so a
    //     transparent one reads as two overlapping lines of text rather than as a header.
    //   * the padding must be INSIDE the background, or the rows show through the gap.
    // `.regularMaterial` rather than a colour: the sheet is a glass surface on visionOS and a
    // solid fill would be a grey card sitting on it.
    @ViewBuilder private func header(_ s: Q2SettingsSection, reset: @escaping () -> Void) -> some View {
        HStack {
            Text(s.title).font(.caption.bold()).foregroundStyle(.secondary)
            Spacer()
            Button("Reset", action: reset).buttonStyle(.bordered).tint(.orange).font(.caption)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
    // A sub-heading INSIDE a section. Deliberately not a pinned Section header of its own: only
    // the two top-level sections carry a Reset, and a second tier of pinned bars would eat the
    // sheet's height in a headset for no control the player can press.
    @ViewBuilder private func subheader(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }.padding(.top, 10)
    }

    private func reset3D() {   // 3D keys only; units + FPS prefs kept (spec)
        dist = 3.6; halfW = 2.75; halfH = 1.55; posH = 0
        sepPct = 100; conv = 240; dim = 0.8; hideGun = false
        // 0.6, matching @AppStorage's default AND xr3_glue.m's C-side fallback. Reset used
        // to write 1.0 — a render budget the app never ships with, so "Reset" made the panel
        // slower than a fresh install. SHELL-GAPS item 7.
        quality = 0.6
        VID_iOS_XR3_ResizeEyes()   // apply the restored aspect/budget now
    }

    private func resetVR() {
        vrHeightTrim = Q2VRDefaults.heightTrim
        vrQuality    = Q2VRDefaults.quality
        vrSharpen    = Q2VRDefaults.sharpen
        vrAimHand    = Q2VRDefaults.aimHand
        vrMoveDir    = Q2VRDefaults.moveDir
        vrSnapStep   = Q2VRDefaults.snapStep
        vrTurnSpeed  = Q2VRDefaults.turnSpeed
        vrCrosshair  = Q2VRDefaults.crosshair
        vrPitchTrim  = Q2VRDefaults.pitchTrim
        vrHudPos     = Q2VRDefaults.hudPos
        vrWeaponSize = Q2VRDefaults.weaponSize
        vrHaptics    = Q2VRDefaults.haptics
        vrHudSize    = Q2VRDefaults.hudSize
        vrHudHeight  = Q2VRDefaults.hudHeight
        vrHudSpread  = Q2VRDefaults.hudSpread
        vrCrossSize  = Q2VRDefaults.crosshairSize
        vrFps        = Q2VRDefaults.fps
        vrPanelSize  = Q2VRDefaults.panelSize
        // The FPS draw-object is engine state, not store state: Reset has to take it off the
        // screen too, or the row reads Off with the counter still drawn.
        VID_iOS_Command("undraw cl_fps")
        // R8 — nothing to reset for the grip any more: it is a shipped constant, and the
        // `q2vrgrip` dev rig is session-only, so a Reset cannot strand it anywhere.
        // AND the height BASELINE, which is not a stored row at all — it is the one-shot
        // capture the trim is a deviation from. A Reset that restored the trim and left a
        // baseline taken while the player was sitting down would leave them the wrong height
        // with every visible control back at its default, which is the worst possible state
        // for them to debug (charter D11).
        Q2_VR_ClearHeightBaseline()
        q2VRBumpGen()
    }

    @ViewBuilder private var section3D: some View {
        row("Screen Distance", $dist, 1.0...8.0, len(dist))
        row("Screen Width", $halfW, 0.6...4.0, len(halfW * 2), resync: true)   // stored half, shown full
        row("Screen Height", $halfH, 0.5...3.0, len(halfH * 2), resync: true)
        row("Screen Position Height", $posH, -1.5...10.0, len(posH, signed: true))
        row("Stereo Depth", $sepPct, 0...320, String(format: "%.0f%%", sepPct))
        row("Crosshair Distance", $conv, 32...512, len(conv * 0.0254))  // 1 unit ≈ 1 inch
        row("Surroundings Dimming", $dim, 0...1, String(format: "%.0f%%", dim * 100))
        // Per-eye render budget as a % of the 8.3 MP vkQuake formula. Q2 rerelease frames
        // through ANGLE are much heavier than Q1 Vulkan — lower this if 3D feels laggy
        // (FOVEATION-PERF-CONSULT.md).
        row("Render Resolution", $quality, 0.4...1.0,
            String(format: "%.0f%%", quality * 100), resync: true)
        // CAS strength: the upscale companion to a reduced budget — restores perceived edge
        // crispness the panel's slight magnification softens. Applies live.
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
                q2SetFpsDraw(on, top: false)
            }
        HStack {
            Text("Units").frame(width: 190, alignment: .leading)
            Picker("", selection: $unitsFt) {
                Text("m").tag(false); Text("ft").tag(true)
            }.pickerStyle(.segmented).frame(width: 160)
            Spacer()
        }
        Button("Recenter Screen") { recenter += 1 }.buttonStyle(.bordered).padding(.top, 4)
    }

    @ViewBuilder private func picker<T: Hashable>(_ label: String, _ sel: Binding<T>,
                                                  _ items: [(String, T)]) -> some View {
        HStack {
            Text(label).frame(width: 190, alignment: .leading)
            Picker("", selection: sel) {
                ForEach(items, id: \.1) { Text($0.0).tag($0.1) }
            }.pickerStyle(.segmented).frame(width: 300)
            Spacer()
        }
    }

    @ViewBuilder private var sectionVR: some View {
        // R7b item 10 — no Exit VR row: the ornament's own button covers leaving, and a second
        // exit BURIED INSIDE THE SHEET is worse than no second exit. R10 — no Enter VR row
        // either (reported: "that's not a setting ... duplicative of the VR ornament"). The
        // ornament is the one affordance in both directions; the console keeps `q2vrenter`.
        // Height: the deviation from the engine's own 46-unit standing eye, shown in inches
        // whatever the Units picker says (a body measurement, not a room measurement).
        row("Height", $vrHeightTrim, -0.5...0.5, inches(vrHeightTrim))
        // [R17] ONE button. Reported: "re-calibrate height doesn't actually fix it, what does is
        // re-center view" — the wrong height after a re-entry was a wrong BASE (the first
        // anchor of a re-entered space, before tracking converged), and only a recentre
        // re-captures the base. VR entry now settles the base by itself (VRShell); this row
        // is the manual repair, and it does the whole re-calibration: the base (position and
        // yaw) AND the standing-height baseline, from where the head is right now.
        HStack(spacing: 12) {
            Button("Re-calibrate Height") {
                Q2_VR_ClearHeightBaseline()
                Q2_VR_RequestRecenter()
            }.buttonStyle(.bordered)
            Spacer()
        }
        // MULTIPLE OF THE PHYSICAL PER-VIEW TEXTURE, not a pixel budget: a VR eye target is
        // sized from the drawable the compositor hands us, and the 3D panel's
        // 3840x2160xquality SCREEN formula is wrong for it in every respect (charter D2).
        // Supersampling is what replaces the MSAA VR cannot use; R9's default is 1.5x
        // (the fourth headset verdict — 1.25 did not resolve enough in the headset).
        row("VR Render Quality", $vrQuality, 0.75...2.0, String(format: "%.2fx", vrQuality))
        if vrQuality >= 1.75 {
            // [R19] The second sentence is the one the 1.0.11.22 report bought. Each
            // 0.25x step here is not a little more work, it is a LOT more memory: the eye
            // targets are five ring slots of colour + depth plus the UI ring plus the
            // compositor's own copies, so the footprint goes as the square of this number
            // (roughly 1.0 GB at 1.5x, 1.7 GB at 2.0x). The engine now measures its own
            // headroom and quietly shortens the ring — and, if it must, the target itself —
            // rather than being killed by the OS with no crash report, which is what a
            // "crash while increasing the render quality" actually was.
            Text("Above about 1.75x the engine renders more than four times the pixels the headset shows and the frame cadence halves. It also needs a lot more memory, and if there is not enough the engine quietly renders a little smaller than this asks. Lower this first if VR feels heavy.")
                .font(.caption2).foregroundStyle(.orange)
        }
        // [R23] The Anti-aliasing row that lived here is gone. Supersampling above is the
        // aliasing lever that survives on this hardware; MSAA cost frames for a difference
        // nobody could see in the headset, twice. `q2vrset vr_msaa N` still drives the
        // xr3_glue backend from the dev console for the next headset that wants measuring.
        row("Sharpen", $vrSharpen, 0...1, String(format: "%.0f%%", vrSharpen * 100))
        Text("The eye image is resampled twice before it reaches your eyes, so a little sharpening buys back most of the perceived detail. 50% is vkQuake's shipped value.")
            .font(.caption2).foregroundStyle(.secondary)
        picker("Aim Hand", $vrAimHand, [("Left", 0), ("Right", 1)])
        picker("Movement Direction", $vrMoveDir,
               [("Head", 0), ("Aim Hand", 2), ("Off Hand", 3)])
        Text("Head works today. The hand options take effect when tracked controllers arrive in the next build.")
            .font(.caption2).foregroundStyle(.secondary)
        picker("Snap Turn", $vrSnapStep,
               [("Smooth", 0.0), ("30°", 30.0), ("45°", 45.0), ("60°", 60.0)])
        row("Turn Speed", $vrTurnSpeed, 60...260, String(format: "%.0f °/s", vrTurnSpeed))
        Toggle("VR Crosshair", isOn: $vrCrosshair)
        row("Crosshair Size", $vrCrossSize, 0.5...3.0, String(format: "%.2fx", vrCrossSize))
        Text("The crosshair is a world mark at whatever you are pointing at, so it keeps the same apparent size at every distance. 1.00x is the 1.2-degree cross Quake II itself draws.")
            .font(.caption2).foregroundStyle(.secondary)
        row("Aim Pitch Trim", $vrPitchTrim, -15...15, String(format: "%+.0f°", vrPitchTrim))
        picker("HUD Position", $vrHudPos, [("High", 0), ("Low", 1), ("Off", 2)])
        Text("Off hides the health and ammo readout only — menus and the console still appear.")
            .font(.caption2).foregroundStyle(.secondary)
        // R7b item 8, extended in R8. HUD Size multiplies the engine's own auto HUD scale —
        // the layout is re-derived at the new scale, so the readout is genuinely BIGGER rather
        // than a magnified texture — until the layout stops fitting at 1.05, past which the
        // remainder magnifies the quad instead. HUD Height moves the quad, on top of whatever
        // High/Low chose.
        row("HUD Size", $vrHudSize, 0.85...2.0, String(format: "%.2fx", vrHudSize))
        row("HUD Height", $vrHudHeight, -0.6...0.6,
            String(format: "%+.2f m", vrHudHeight))
        // [R23] HUD SPREAD. It composes with Size rather than competing with it: Size still
        // decides how big an element is (layout below 1.05, quad magnification above), and
        // Spread multiplies BOTH the virtual canvas and the quad, which cancels for the
        // elements and leaves only the gaps between them larger. Costs nothing — the UI
        // texture and the HUD's sub-rect in it are unchanged; only the virtual-to-pixel scale
        // moves — and it cannot clip, because a wider canvas is the direction the engine's
        // fixed 320-unit status strip is always safe in.
        row("HUD Spread", $vrHudSpread, 1.0...2.0, String(format: "%.2fx", vrHudSpread))
        Text("Size re-lays the HUD out larger (not a zoom, so it stays sharp) — above about 1.05x the panel is magnified rather than re-laid-out, so it gets a little softer. Height raises or lowers the whole panel from the High/Low preset. Spread pushes the health bar and the messages further apart without changing how big any of them looks — the same text on a larger screen.")
            .font(.caption2).foregroundStyle(.secondary)
        // [R21] MENU PANEL SIZE. The menus, the console and demo/cinematic playback are not
        // world frames: they arrive as a 16:9 sub-rect of the eye texture that the compositor
        // shows on ONE floating quad, and that quad's size was a constant 44 degrees across
        // until it was called too small in the headset. It is an ANGLE, not a width, because
        // the quad sits at a fixed 3 m and an angle is what the player actually perceives.
        // 40...90: at 90 the panel spans nearly the whole horizontal field, and at 16:9 its
        // half-height is still only 25 degrees, so the bottom menu row stays inside the eye's
        // ~50-degree downward reach at every point on the row.
        row("Menu Panel Size", $vrPanelSize, 40...90, String(format: "%.0f\u{00B0} wide", vrPanelSize))
        Text("How large the menus, the console and demo playback appear. This is the floating screen you see when the game is not drawing the world — it does not change the size of anything in VR itself.")
            .font(.caption2).foregroundStyle(.secondary)
        row("Weapon Size", $vrWeaponSize, 0.5...3.0, String(format: "%.2fx", vrWeaponSize))
        Text("1.0x is the size the gun ships at; the slider runs to twice that. It scales about the point in your fist, so the gun never leaves your hand.")
            .font(.caption2).foregroundStyle(.secondary)
        Toggle("Controller Haptics", isOn: $vrHaptics)
        // [R21] THE FPS COUNTER, replacing R10's nine-number VR Stats block. The engine's own
        // draw-object, exactly as the 3D panel's "FPS on Panel" row uses it — the VR 2D pass is
        // redirected onto the UI texture, so it lands on the HUD quad. `-4 4`: negative x
        // anchors from the right, positive y measures from the top, so this is the TOP-right
        // corner (SCR_DrawObjects, screen.c). Draw-objects do not survive a relaunch, so VR
        // entry re-applies this (enterSpace).
        Toggle("FPS Counter", isOn: $vrFps)
            .onChange(of: vrFps) { _, on in
                q2SetFpsDraw(on, top: true)
            }
        Text("A small counter in the top corner of the HUD. It counts ENGINE frames per second — the rate the game itself renders at; the headset's own display rate is separate and does not follow it.")
            .font(.caption2).foregroundStyle(.secondary)
        if Q2_iOS_RemoteConsoleAvailable() != 0 {
            // [R10] Dev builds only — the function returns 0 and the row vanishes in a public
            // build. The switch is remembered and defaults ON in a dev build, so the console is
            // reachable over the tailnet without anyone typing a command in the headset.
            subheader("Developer", "Only in OTA test builds.")
            Toggle("Remote Console", isOn: $rconOn)
                .onChange(of: rconOn) { _, on in Q2_iOS_RemoteConsole(on ? 1 : 0) }
                .onAppear { rconOn = Q2_iOS_RemoteConsoleRunning() != 0 }
            Text("Listens on tcp/8770 over the tailnet so a Mac can read the engine's counters while you play.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // R8 — the WEAPON PLACEMENT (TUNING) subsection is gone. R7b promoted `q2vrgrip` to six
    // sliders so the mount could be dialled in the headset with no keyboard; it was, on
    // 1.0.11.10, and the numbers found are the shipped constant now. Six sliders that will
    // never be moved again are six ways to put the gun somewhere a player cannot recover it
    // from. The rig survives as the dev-only console command it started as.

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
            // LazyVStack + pinnedViews is what makes `Section(header:)` STICK; a plain VStack
            // ignores the pin and a `List` would re-style every row (and, on visionOS, inset
            // and background them) for the sake of one behaviour. The horizontal padding moved
            // OFF this container and onto the rows, because a pinned header has to span the
            // full width or the rows scroll visibly past its edges.
            // Harness seam (sim only): ScrollViewReader so Q2_XR_SETTINGS_SCROLL=bottom can
            // park the sheet at its END. The visionOS simulator accepts no injected taps, so
            // without this no screenshot can ever show a row below the fold.
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12,
                           pinnedViews: [.sectionHeaders]) {
                    ForEach(sections, id: \.title) { s in
                        // Keyed by TITLE, not by index — the same rule the Reset wiring uses,
                        // and the reason the tri-state visibility rule can drop a section
                        // without renumbering anything.
                        switch s {
                        case .threeD:
                            Section(header: header(.threeD, reset: reset3D)) {
                                VStack(alignment: .leading, spacing: 12) { section3D }
                                    .padding(.horizontal, 24)
                            }
                        case .vr:
                            Section(header: header(.vr, reset: resetVR)) {
                                VStack(alignment: .leading, spacing: 12) { sectionVR }
                                    .padding(.horizontal, 24)
                            }
                            // [R21] The VR section's own scroll anchor. The sheet is long
                            // enough that "top" and "bottom" cannot both show a middle row,
                            // and the middle is where VR Render Quality lives — so a
                            // screenshot could not evidence it at all.
                            .id("q2-sheet-vr")
                        }
                    }
                    Color.clear.frame(height: 1).id("q2-sheet-end")
                }.padding(.bottom, 20)
            }
            .onAppear {
                // [R21] Two destinations now: "bottom" parks at the sheet's end, "vr" at the
                // TOP of the VR section. Anything else (or unset) leaves the sheet where it
                // opened. Sim-only harness seam either way — the visionOS simulator accepts
                // no injected taps, so this is the only way a screenshot reaches a row that
                // is not on the first screen.
                let want = ProcessInfo.processInfo.environment["Q2_XR_SETTINGS_SCROLL"] ?? ""
                let target: (String, UnitPoint)? = want == "bottom" ? ("q2-sheet-end", .bottom)
                                                 : want == "vr"     ? ("q2-sheet-vr", .top)
                                                 : nil
                guard let target else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    proxy.scrollTo(target.0, anchor: target.1)
                }
            }
            }
        }
        .frame(minWidth: 900)   // width ONLY (forced height center-clips — spec trap)
        .onAppear {
            q2VRMigrateSettings()
            sections = q2SettingsSections(for: model.mode)
            Q2_XR3_Log("SETTINGSOPEN mode=\(model.mode.rawValue) sections=" +
                       sections.map(\.token).joined(separator: "+"))
        }
        // One bump per group rather than per row: the engine only needs to know that
        // SOMETHING moved, and grouping keeps this from becoming twelve near-identical
        // modifiers that a new row can be forgotten out of.
        .onChange(of: [vrHeightTrim, vrQuality, vrSharpen, vrSnapStep, vrTurnSpeed,
                       vrPitchTrim, vrWeaponSize]) { _, _ in q2VRBumpGen() }
        .onChange(of: [vrAimHand, vrMoveDir, vrHudPos]) { _, _ in q2VRBumpGen() }
        .onChange(of: [vrCrosshair, vrHaptics, vrFps]) { _, _ in q2VRBumpGen() }
        .onChange(of: [vrPanelSize]) { _, _ in q2VRBumpGen() }
        .onChange(of: [vrCrossSize]) { _, _ in q2VRBumpGen() }
        .onChange(of: [vrHudSize, vrHudHeight, vrHudSpread]) { _, _ in q2VRBumpGen() }
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
    // Written on the RENDER thread (run()'s entry and its defer), read on the MainActor
    // (the exit handshake). Unsynchronized this is a data race on a class reference —
    // benign-looking, and exactly the kind that turns into a use-after-free the first time
    // an exit and an invalidation land together. One lock, shared with stop/running.
    private static let currentLock = NSLock()
    private static var _current: Q2PanelRenderer?
    static var current: Q2PanelRenderer? {
        get { currentLock.lock(); defer { currentLock.unlock() }; return _current }
        set { currentLock.lock(); _current = newValue; currentLock.unlock() }
    }
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
        var pausedTicks = 0
        while !stopRequested {
            switch layer.state {
            case .paused:
                // layer.waitUntilRunning() blocks with NO timeout and no way to observe
                // stopRequested from inside it, so a stop landing on a paused layer left
                // this thread parked while the exit path's 2 s handshake expired and
                // dismissed the space out from under it (guide §10 #9). Poll instead:
                // the wait on any one call is bounded to 10 ms and the stop flag is
                // re-tested every iteration. Staying paused is legitimate (the headset
                // is off the head), so only the BLOCKING is bounded, never the pause.
                Thread.sleep(forTimeInterval: 0.01)
                pausedTicks += 1
                if pausedTicks == 500 { Q2_XR3_Log("xr3 layer paused >5s (still waiting)") }
            case .running:
                pausedTicks = 0
                autoreleasepool { frame() }
            case .invalidated:
                // Digital Crown / system dismissal: reconcile the SwiftUI state so the
                // engine returns to the window and the button reads "3D" again.
                DispatchQueue.main.async {
                    if Q2AppModel.shared.mode == .panel {
                        Q2AppModel.shared.mode = .flat        // triggers dismiss+exit path
                    } else {
                        // Belt for an invalidation that arrives with the state already
                        // reconciled: the onChange finalize is transition-driven, so it
                        // would not run and nothing would persist the config. Both of
                        // these are idempotent.
                        Q2_iOS_AutoPause()
                        Q2_iOS_WriteConfigSync()
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
