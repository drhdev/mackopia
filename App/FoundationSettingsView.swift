import SwiftUI

struct FoundationSettingsView: View {
    @Environment(AgentConnection.self) private var connection
    var body: some View {
        Form {
            Section("Hintergrunddienst") {
                if let message = connection.registrationMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                }
                Button("Hintergrunddienst aktivieren") { connection.enable() }
                Button("Anmeldeobjekte öffnen…") { connection.openLoginSettings() }
                Button("Erneut verbinden") { connection.reconnect() }
            }
            Section("Mitteilungen") {
                Toggle(
                    "Bei Problemen und erstem Erfolg benachrichtigen",
                    isOn: Binding(
                        get: { connection.state?.configuration?.notificationsEnabled ?? false },
                        set: { connection.send(.setNotificationsEnabled($0)) })
                )
                .disabled(!connection.canConfigure)
                Text(
                    "Fehler und kritische Zustände werden höchstens einmal täglich gemeldet. Regelmäßige Erfolgsmeldungen bleiben aus."
                )
            }
            Section("Berechtigungen") {
                Text("Der Quellenzugriff wird vor jedem Backup geprüft. Nicht bestätigte Zugriffe bleiben gesperrt.")
                Button("Festplattenvollzugriff öffnen…") { connection.openPrivacySettings() }
            }
        }.formStyle(.grouped).frame(minWidth: 520, minHeight: 300)
    }
}

#Preview { FoundationSettingsView().environment(AgentConnection(preview: true)) }
