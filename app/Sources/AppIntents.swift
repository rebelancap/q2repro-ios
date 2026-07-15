// App Intents — native Siri / Shortcuts actions for launching a Quake II game or mod.
// Hands the request to the ObjC app via UserDefaults (read on launch/foreground);
// the URL scheme (q2repro://) covers the same deep links for manual shortcuts.
import AppIntents
import Foundation

@available(iOS 16.0, *)
struct LaunchGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Launch Game"
    static var description = IntentDescription("Launch a Quake II game or mod (e.g. Action Quake).")
    static var openAppWhenRun = true

    @Parameter(title: "Game or mod", default: "menu")
    var game: String

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(game, forKey: "q2_pending_launch")
        return .result()
    }
}

@available(iOS 16.0, *)
struct Q2AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LaunchGameIntent(),
                    phrases: ["Launch \(.applicationName)",
                              "Play \(.applicationName)"],
                    shortTitle: "Launch Game",
                    systemImageName: "gamecontroller")
    }
}
