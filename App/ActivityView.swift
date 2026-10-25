import SwiftUI

struct ActivityView: View {
    @Environment(AgentConnection.self) private var connection
    var body: some View {
        Table(connection.state?.runs ?? []) {
            TableColumn("Beginn") { run in Text(run.startedAt, format: .dateTime) }
            TableColumn("Ergebnis") { run in Text(AgentConnection.outcome(run.outcome)) }
        }
        .overlay {
            if connection.state?.runs.isEmpty ?? true {
                ContentUnavailableView(
                    "Noch keine Sicherungen", systemImage: "clock",
                    description: Text("Starte dein erstes Backup über „Jetzt sichern“."))
            }
        }
    }
}

#Preview { ActivityView().environment(PreviewData.connection()) }
