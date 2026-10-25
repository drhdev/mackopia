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
            if store.state?.globalPause != nil {
                Label("Alle Backups pausiert", systemImage: "pause.circle")
                Button("Fortsetzen") { store.resume() }
            }
            Menu("Pausieren") {
                Button("Für eine Stunde") { store.pause(.oneHour) }
                Button("Bis morgen um 08:00") { store.pause(.untilTomorrowMorning) }
                Button("Unbegrenzt") { store.pause(.indefinite) }
            }
            ForEach(store.state?.plans ?? []) { plan in
                LabeledContent(store.name(plan.planID)) {
                    if let date = plan.health.lastSuccessfulBackup {
                        Text(date, format: .relative(presentation: .named))
                    }
                }
                Label(
                    plan.health.severity == .ok ? "Backups aktuell und geprüft" : "Aktion erforderlich",
                    systemImage: plan.health.severity == .ok ? "checkmark.circle" : "exclamationmark.triangle")

            }
            Divider()
            Button("MacKopia öffnen") { store.openApp() }
        }
        .padding()
    }
}

#Preview { AgentStatusView().environment(AgentRuntimeStore()) }
