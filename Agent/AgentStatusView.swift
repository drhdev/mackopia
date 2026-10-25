import SwiftUI

struct AgentStatusView: View {
    @Environment(AgentRuntimeStore.self) private var store

    var body: some View {
        VStack(alignment: .leading) {
            if store.unavailable {
                Label("Hintergrunddienst nicht verfügbar", systemImage: "exclamationmark.triangle")
            } else if let id = store.state?.activePlanID {
                Label("Backup läuft", systemImage: "arrow.triangle.2.circlepath")
                ProgressView()
                Button("Stoppen") { store.stop(id) }
            } else if let plans = store.state?.configuration?.plans, !plans.isEmpty {
                ForEach(plans) { plan in
                    LabeledContent(plan.name) { Button("Jetzt sichern") { store.run(plan.id) } }
                }
                if store.state?.issue != nil {
                    Label("Aktion erforderlich", systemImage: "exclamationmark.triangle")
                }
            } else {
                Label("Noch keine Backups eingerichtet", systemImage: "info.circle")
            }
            if let run = store.state?.runs.first(where: {
                $0.outcome == .succeeded || $0.outcome == .succeededWithWarnings
            }) {
                LabeledContent("Letztes erfolgreiches Backup") {
                    Text(run.startedAt, format: .relative(presentation: .named))
                }
            }
            Divider()
            Button("MacKopia öffnen") { store.openApp() }
        }
        .padding()
    }
}

#Preview { AgentStatusView().environment(AgentRuntimeStore()) }
