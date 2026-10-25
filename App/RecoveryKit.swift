import AppKit
import BackupDomain
import SwiftUI

/// Uses the native print panel, including Save as PDF. Passwords never enter this document.
@MainActor
enum RecoveryKit {
    static func printKit(connection: AgentConnection, repositoryID: UUID?) {
        guard let repository = connection.state?.configuration?.repositories.first(where: { $0.id == repositoryID }),
            case .filesystem(let path, _) = repository.kind
        else { return }
        let content = RecoveryKitPage(
            name: repository.name, path: path,
            identity: repository.identity, date: .now)
        let view = NSHostingView(rootView: content)
        view.frame = NSRect(x: 0, y: 0, width: 560, height: 720)
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = String(localized: "MacKopia Wiederherstellungs-Kit")
        operation.run()
    }
}

private struct RecoveryKitPage: View {
    let name: String
    let path: String
    let identity: SnapshotIdentity
    let date: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MacKopia Wiederherstellungs-Kit").font(.title)
            Text(date, format: .dateTime.year().month().day())
            LabeledContent("Speicherziel", value: name)
            LabeledContent("Typ", value: String(localized: "Lokales Dateisystem"))
            Text(path).textSelection(.enabled)
            LabeledContent("Benutzer", value: identity.overrideUser)
            LabeledContent("Rechner", value: identity.overrideHost)
            LabeledContent("Kopia-Version", value: "0.23.1")
            Text(
                "Bewahre dieses Dokument getrennt vom Backup auf. Das Backup-Passwort ist nicht enthalten. Ohne dieses Passwort sind deine Backups unwiederbringlich verloren."
            )
            Text("Wiederherstellen ohne MacKopia").font(.headline)
            Text(
                "1. Installiere Kopia 0.23.1 von kopia.io und schließe das Speicherziel an. Verwende eine eigene Konfigurationsdatei, einen eigenen Cache und Logordner."
            )
            Text(
                "2. Verbinde das vorhandene Speicherziel mit dem folgenden Befehl. Ersetze die Platzhalter durch lokale absolute Pfade. Gib das Backup-Passwort nur an der verdeckten Eingabeaufforderung ein."
            )
            Text(
                "kopia repository connect filesystem --path=\"<destination>\" --config-file=\"<config>\" --log-dir=\"<logs>\" --cache-directory=\"<cache>\""
            )
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(
                "3. Liste die Backups auf. Wähle die gewünschte Snapshot-ID; Benutzer und Rechner können vom aktuellen Mac abweichen."
            )
            Text("kopia snapshot list --all --config-file=\"<config>\" --log-dir=\"<logs>\"")
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(
                "4. Stelle die ausgewählte ID in einem neuen, noch nicht vorhandenen Zielordner wieder her. Prüfe anschließend Dateien und Inhalte."
            )
            Text(
                "kopia snapshot restore \"<snapshot-id>\" \"<new-folder>\" --no-overwrite-files --no-overwrite-directories --no-overwrite-symlinks --config-file=\"<config>\" --log-dir=\"<logs>\""
            )
            .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(
                "Berechtigungen und Zeitstempel werden übernommen. Erweiterte Attribute, Finder-Tags, Ressourcen-Forks und ACLs können fehlen."
            )
            .font(.caption)
            Spacer()
        }.padding().foregroundStyle(.black).background(.white)
    }
}

#Preview {
    if let identity = try? SnapshotIdentity(overrideUser: "example", overrideHost: "example") {
        RecoveryKitPage(name: "Example", path: "/example/destination", identity: identity, date: .now)
    }
}
