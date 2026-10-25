import BackupDomain
import SwiftUI

struct PlanRuntimeView: View {
    @Environment(AgentConnection.self) private var connection
    let runtime: PlanRuntimeState

    var body: some View {
        VStack(alignment: .leading) {
            Label(healthTitle, systemImage: symbol).foregroundStyle(color)
            ForEach(runtime.health.reasons, id: \.self) { reason in
                LabeledContent {
                    Button(actionTitle(reason.action)) { act(reason.action) }.disabled(connection.busy)
                } label: {
                    Text(reasonTitle(reason))
                }
            }
            if let issue = runtime.issue { Text(AgentConnection.description(issue)) }
            if let pause = runtime.pause {
                switch pause {
                case .indefinite: Text("Pausiert – bereits gesicherte Daten bleiben erhalten.")
                case .until(let date):
                    LabeledContent("Pausiert bis") { Text(date, format: .dateTime) }
                case .timerUnavailable:
                    Text("Pause kann nicht automatisch enden. Setze den Plan manuell fort.")
                }
                Button("Fortsetzen") { connection.resume(runtime.planID) }
            } else if let next = runtime.nextRun {
                LabeledContent("Nächstes Backup") { Text(next, format: .dateTime) }
            }
            if let check = runtime.verification {
                LabeledContent(check.outcome == .succeeded ? "Zuletzt erfolgreich geprüft" : "Prüfung fehlgeschlagen") {
                    Text(check.endedAt, format: .dateTime)
                }
            }
            if let check = runtime.testRestore {
                LabeledContent(
                    check.outcome == .succeeded
                        ? "Wiederherstellung erfolgreich getestet" : "Test-Wiederherstellung fehlgeschlagen"
                ) {
                    Text(check.endedAt, format: .dateTime)
                }
            }
            if let maintenance = runtime.maintenance {
                LabeledContent(maintenance.outcome == .succeeded ? "Wartung abgeschlossen" : "Wartung fehlgeschlagen") {
                    Text(maintenance.endedAt, format: .dateTime)
                }
            }
        }
    }
    private var healthTitle: String {
        switch runtime.health.severity {
        case .ok: String(localized: "Backups aktuell und geprüft")
        case .warning: String(localized: "Aktion empfohlen")
        case .critical: String(localized: "Aktion erforderlich")
        }
    }
    private var symbol: String {
        switch runtime.health.severity {
        case .ok: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon"
        }
    }
    private var color: Color {
        switch runtime.health.severity {
        case .ok: .green
        case .warning: .orange
        case .critical: .red
        }
    }
    private func actionTitle(_ action: HealthAssessment.Action) -> String {
        switch action {
        case .backUpNow: String(localized: "Jetzt sichern")
        case .openFullDiskAccess: String(localized: "Festplattenvollzugriff öffnen…")
        case .enableBackgroundService: String(localized: "Hintergrunddienst aktivieren")
        case .runVerification: String(localized: "Prüfen")
        default: String(localized: "Details anzeigen")
        }
    }
    private func act(_ action: HealthAssessment.Action) {
        switch action {
        case .backUpNow: connection.runSelected(runtime.planID)
        case .openFullDiskAccess: connection.openPrivacySettings()
        case .enableBackgroundService: connection.enable()
        case .runVerification: connection.send(.verify(runtime.planID))
        default: connection.showActivity = true
        }
    }
    private func reasonTitle(_ reason: HealthAssessment.Reason) -> String {
        switch reason {
        case .backupOverdue, .backupCriticallyOverdue: String(localized: "Backup überfällig")
        case .noSuccessfulBackup: String(localized: "Noch kein erfolgreiches Backup")
        case .lastRunWarnings: String(localized: "Letztes Backup enthält Hinweise")
        case .lastRunFailed: String(localized: "Letztes Backup fehlgeschlagen")
        case .destinationNearlyFull: String(localized: "Speicherziel fast voll")
        case .passwordMissing, .passwordIncorrect: String(localized: "Backup-Passwort prüfen")
        case .fullDiskAccessMissing: String(localized: "Quellenzugriff nicht bestätigt")
        case .backgroundServiceDisabled: String(localized: "Hintergrunddienst nicht aktiv")
        case .verificationOverdue: String(localized: "Prüfung überfällig")
        case .verificationFailed: String(localized: "Prüfung fehlgeschlagen")
        case .verificationUnavailable: String(localized: "Noch kein Prüfnachweis")
        case .testRestoreFailed: String(localized: "Test-Wiederherstellung fehlgeschlagen")
        case .maintenanceFailed: String(localized: "Wartung fehlgeschlagen")
        case .historyUnavailable: String(localized: "Verlauf nicht verfügbar")
        case .suspiciousSnapshot: String(localized: "Ungewöhnlich wenige Daten gesichert")
        case .snapshotPinFailed: String(localized: "Schutz des letzten Backups nicht bestätigt")
        }
    }
}

#Preview {
    let connection = PreviewData.connection()
    FoundationView().environment(connection)
}

#Preview("Paused") { FoundationView().environment(PreviewData.connection(paused: true)) }
#Preview("Critical") { FoundationView().environment(PreviewData.connection(critical: true)) }
