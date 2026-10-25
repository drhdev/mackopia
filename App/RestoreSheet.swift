import SwiftUI

struct RestoreSheet: View {
    @Environment(RestoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            LabeledContent("Auswahl", value: store.selectionLabel)
            if store.snapshots.first(where: { $0.id == store.selectedSnapshotID })?.isIncomplete == true {
                Label("Unvollständiges Backup", systemImage: "exclamationmark.triangle")
            }
            Text(
                "Die Wiederherstellung erstellt einen neuen Ordner im gewählten Ziel. Vorhandene Dateien bleiben erhalten."
            )
            LabeledContent("Zielordner") {
                Text(store.destination?.path ?? String(localized: "Bitte wählen"))
                    .lineLimit(1).truncationMode(.middle).help(store.destination?.path ?? "")
                Button("Wählen…") { store.chooseDestination() }
            }
            Text(
                "Berechtigungen und Zeitstempel werden übernommen. Erweiterte Attribute, Finder-Tags, Ressourcen-Forks und ACLs können fehlen."
            )
            .foregroundStyle(.secondary)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Wiederherstellen") { store.startRestore() }.buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(store.destination == nil || !store.canBrowse)
            }
        }.formStyle(.grouped).padding().frame(minWidth: 560, minHeight: 320)
            .task { await store.prepareDestination() }
    }
}

struct RestoreProgressView: View {
    @Environment(RestoreStore.self) private var store
    var body: some View {
        if let state = store.connection.state?.restore, state.phase != .idle {
            GroupBox {
                VStack(alignment: .leading) {
                    Label(
                        store.phaseLabel,
                        systemImage: state.phase == .succeeded ? "checkmark.circle" : "arrow.counterclockwise")
                    if state.phase == .running {
                        ProgressView().accessibilityLabel(Text("Wiederherstellung läuft"))
                            .accessibilityValue(Text(state.bytes, format: .byteCount(style: .file)))
                        HStack {
                            Text(state.bytes, format: .byteCount(style: .file)).monospacedDigit()
                            Text(state.files, format: .number).monospacedDigit()
                            Button("Abbrechen") { store.cancel() }.disabled(store.connection.busy)
                        }
                    } else {
                        if state.phase == .failed || state.phase == .cancelled {
                            Text(
                                "Bereits wiederhergestellte Dateien bleiben erhalten. Prüfe das Speicherziel und versuche es erneut."
                            )
                        }
                        if state.destination != nil { Button("Im Finder zeigen") { store.showInFinder() } }
                    }
                }
            }
        }
    }
}

#Preview { RestoreSheet().environment(RestorePreviewData.store()) }
#Preview { RestoreProgressView().environment(RestorePreviewData.store(phase: .running)) }
