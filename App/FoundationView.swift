import BackupDomain
import SwiftUI

struct FoundationView: View {
    enum Route: String, Hashable { case overview, plans, destinations, activity }
    @Environment(AgentConnection.self) private var connection
    @SceneStorage("navigation") private var savedRoute = Route.overview.rawValue
    private var selection: Binding<Route?> {
        Binding(get: { Route(rawValue: savedRoute) }, set: { savedRoute = ($0 ?? .overview).rawValue })
    }

    var body: some View {
        @Bindable var connection = connection
        NavigationSplitView {
            List(selection: selection) {
                Label("Übersicht", systemImage: "house").tag(Route.overview)
                Label("Backup-Pläne", systemImage: "list.bullet").tag(Route.plans)
                Label("Speicherziele", systemImage: "externaldrive").tag(Route.destinations)
                Label("Aktivität", systemImage: "clock").tag(Route.activity)
            }
        } detail: {
            VStack(spacing: 0) {
                if !connection.connected {
                    ContentUnavailableView {
                        Label("Hintergrunddienst nicht aktiv", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("Aktiviere den Hintergrunddienst, damit MacKopia Backups ausführen kann.")
                    } actions: {
                        Button("Hintergrunddienst aktivieren") { connection.enable() }
                        if connection.requiresApproval {
                            Button("Anmeldeobjekte öffnen…") { connection.openLoginSettings() }
                        }
                        Button("Erneut verbinden") { connection.reconnect() }
                    }
                } else {
                    if let message = connection.message {
                        GroupBox {
                            VStack(alignment: .leading) {
                                Label(message, systemImage: "exclamationmark.triangle")
                                HStack {
                                    Button("Erneut verbinden") { connection.reconnect() }
                                    if connection.state?.issue == .automationUnavailable {
                                        Button("Automatik neu starten") { connection.send(.restartAutomation) }
                                    }
                                    if connection.state?.issue == .safeMode {
                                        Button("Konfigurationssicherung wiederherstellen…") {
                                            connection.showRecovery = true
                                        }
                                    }
                                    if connection.state?.issue == .permissions {
                                        Button("Festplattenvollzugriff öffnen…") { connection.openPrivacySettings() }
                                    }
                                }
                            }
                        }.padding()
                    }
                    if connection.state?.globalPause != nil {
                        LabeledContent("Alle Backups pausiert") {
                            Button("Fortsetzen") { connection.resume() }
                        }.padding()
                    }
                    content
                }
            }
            .navigationTitle("MacKopia")
            .toolbar {
                Button("Neuer Plan…", systemImage: "plus") { connection.showSetup = true }
                    .help("Neuer Plan…").accessibilityLabel(Text("Neuer Plan…")).disabled(!connection.canConfigure)
                Button("Jetzt sichern", systemImage: "play.fill") { connection.runSelected() }
                    .help("Jetzt sichern").accessibilityLabel(Text("Jetzt sichern")).disabled(!connection.canRun)
                Menu("Pausieren", systemImage: "pause") {
                    Button("Für eine Stunde") { connection.pause(.oneHour) }
                    Button("Bis morgen um 08:00") { connection.pause(.untilTomorrowMorning) }
                    Button("Unbegrenzt") { connection.pause(.indefinite) }
                    Button("Fortsetzen") { connection.resume() }
                }.disabled(!connection.connected || connection.busy)
                Button("Stoppen", systemImage: "stop.fill") { connection.stop() }
                    .help("Stoppen").accessibilityLabel(Text("Stoppen")).disabled(
                        connection.state?.activePlanID == nil || connection.busy)
            }
        }
        .frame(minWidth: 800, minHeight: 520)
        .task { connection.start() }
        .onChange(of: connection.showActivity) { _, requested in
            if requested { savedRoute = Route.activity.rawValue; connection.showActivity = false }
        }
        .confirmationDialog("Konfiguration wiederherstellen?", isPresented: $connection.showRecovery) {
            Button("Wiederherstellen") { connection.send(.recoverConfiguration) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die letzte gültige Sicherung ersetzt die aktuelle Konfiguration. Deine Backups bleiben erhalten.")
        }
        .sheet(isPresented: $connection.showSetup) {
            LocalSetupView().environment(LocalSetupStore(connection: connection))
        }
        .sheet(item: $connection.editingPlan) {
            PlanEditorView().environment(PlanEditorStore(plan: $0, connection: connection))
        }
    }

    @ViewBuilder private var content: some View {
        if savedRoute == Route.activity.rawValue {
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
        } else if savedRoute == Route.destinations.rawValue {
            List(connection.state?.configuration?.repositories ?? []) { repository in
                LabeledContent(repository.name) {
                    if case .filesystem(let path, _) = repository.kind {
                        Text(path).lineLimit(1).truncationMode(.middle).help(path)
                    }
                }
            }
        } else if let plans = connection.state?.configuration?.plans, !plans.isEmpty {
            Form {
                if let progress = connection.state?.progress {
                    Section("Backup läuft") {
                        ProgressView(value: progress.fractionCompleted)
                        if let bytes = progress.uploadedBytes {
                            Text(bytes, format: .byteCount(style: .file)).monospacedDigit()
                        }
                    }
                } else if connection.state?.activePlanID != nil {
                    Section { ProgressView("Backup wird vorbereitet") }
                }
                ForEach(plans) { plan in
                    Section(plan.name) {
                        if let runtime = connection.state?.plans.first(where: { $0.planID == plan.id }) {
                            PlanRuntimeView(runtime: runtime)
                        }
                        if let run = connection.state?.runs.first(where: { $0.planID == plan.id }) {
                            Label(
                                AgentConnection.outcome(run.outcome),
                                systemImage: run.outcome == .succeeded ? "checkmark.circle" : "exclamationmark.triangle"
                            )
                        }
                        if let success = connection.lastSuccess(plan.id) {
                            LabeledContent("Letztes erfolgreiches Backup") {
                                Text(success.startedAt, format: .relative(presentation: .named))
                            }
                        } else {
                            Label("Noch kein erfolgreiches Backup", systemImage: "exclamationmark.triangle")
                        }
                        ForEach(plan.sources) { source in
                            Label(source.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(
                                source.path)
                        }
                        HStack {
                            Button("Jetzt sichern") { connection.runSelected(plan.id) }.disabled(
                                !connection.canConfigure || !plan.isEnabled)
                            Menu("Pausieren") {
                                Button("Für eine Stunde") { connection.pause(.oneHour, planID: plan.id) }
                                Button("Bis morgen um 08:00") {
                                    connection.pause(.untilTomorrowMorning, planID: plan.id)
                                }
                                Button("Unbegrenzt") { connection.pause(.indefinite, planID: plan.id) }
                                Button("Fortsetzen") { connection.resume(plan.id) }
                            }.disabled(connection.busy)
                            Button("Prüfen") { connection.send(.verify(plan.id)) }.disabled(
                                !connection.canConfigure || !plan.isEnabled)
                            Button("Bearbeiten…") { connection.editingPlan = plan }.disabled(!connection.canConfigure)
                        }
                    }
                    .contextMenu {
                        Button("Jetzt sichern") { connection.runSelected(plan.id) }.disabled(
                            !connection.canConfigure || !plan.isEnabled)
                        Button("Bearbeiten…") { connection.editingPlan = plan }.disabled(!connection.canConfigure)
                    }
                }
            }.formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("Noch kein Backup-Plan", systemImage: "externaldrive.badge.timemachine")
            } description: {
                Text("Erstelle deinen ersten Plan.")
            } actions: {
                Button("Neuer Plan…") { connection.showSetup = true }.buttonStyle(.borderedProminent).disabled(
                    !connection.canConfigure)
            }
        }
    }
}

#Preview("Plans") { FoundationView().environment(PreviewData.connection()) }
#Preview("Empty") { FoundationView().environment(PreviewData.connection(empty: true)) }
#Preview("Permissions") { FoundationView().environment(PreviewData.connection(issue: .permissions)) }
#Preview("Offline") { FoundationView().environment(AgentConnection(preview: true)) }
