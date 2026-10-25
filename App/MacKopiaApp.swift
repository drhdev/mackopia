import SwiftUI

@main
struct MacKopiaApp: App {
    @State private var connection = AgentConnection()
    var body: some Scene {
        WindowGroup { FoundationView().environment(connection) }
            .commands {
                CommandGroup(after: .newItem) {
                    Button("Neuer Plan…") { connection.showSetup = true }.keyboardShortcut("n").disabled(
                        !connection.canConfigure)
                    Button("Jetzt sichern") { connection.runSelected() }.keyboardShortcut("b").disabled(
                        !connection.canRun)
                    Button("Stoppen") { connection.stop() }.keyboardShortcut(".").disabled(
                        connection.state?.activePlanID == nil)
                }
            }
        Settings { FoundationSettingsView().environment(connection) }
    }
}
