import SwiftUI

struct FoundationSettingsView: View {
    @Environment(AgentConnection.self) private var connection
    var body: some View {
        Form {
            Section("Hintergrunddienst") {
                Button("Hintergrunddienst aktivieren") { connection.enable() }
                Button("Anmeldeobjekte öffnen…") { connection.openLoginSettings() }
                Button("Erneut verbinden") { connection.reconnect() }
            }
            Section("Berechtigungen") {
                Text("Der Quellenzugriff wird vor jedem Backup geprüft. Nicht bestätigte Zugriffe bleiben gesperrt.")
                Button("Festplattenvollzugriff öffnen…") { connection.openPrivacySettings() }
            }
        }.formStyle(.grouped).frame(minWidth: 520, minHeight: 300)
    }
}

#Preview { FoundationSettingsView().environment(AgentConnection(preview: true)) }
