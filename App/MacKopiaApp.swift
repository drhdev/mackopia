import SwiftUI

@main
struct MacKopiaApp: App {
    @State private var connection = AgentConnection()
    var body: some Scene {
        WindowGroup { FoundationView().environment(connection) }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Neuer Plan…") { connection.showSetup = true }.keyboardShortcut("n").disabled(
                        !connection.canConfigure)
                    Button("Jetzt sichern") { connection.runSelected() }.keyboardShortcut("b").disabled(
                        !connection.canRun)
                    Button("Wiederherstellen…") { connection.showRestore = true }.keyboardShortcut("r")
                    Button("Stoppen") { connection.stop() }.keyboardShortcut(".").disabled(
                        (connection.state?.activePlanID == nil && connection.state?.restore?.phase != .running)
                            || connection.busy)
                }
            }
        Settings { FoundationSettingsView().environment(connection) }
    }
}
