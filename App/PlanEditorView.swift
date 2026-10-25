import BackupDomain
import SwiftUI

struct PlanEditorView: View {
    @Environment(PlanEditorStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack {
            Form {
                TextField("Name", text: $store.name)
                Toggle("Backup-Plan aktiv", isOn: $store.enabled)
                Section("Quellen") {
                    ForEach(store.sources) { source in
                        LabeledContent {
                            Button("Entfernen", systemImage: "minus") { store.removeSource(source.id) }
                                .help("Quelle entfernen").disabled(store.sources.count <= 1)
                        } label: {
                            Label(source.path, systemImage: "folder").lineLimit(1).truncationMode(.middle).help(
                                source.path)
                        }
                        .contextMenu {
                            Button("Quelle entfernen") { store.removeSource(source.id) }.disabled(
                                store.sources.count <= 1)
                        }
                    }
                    Button("Quelle hinzufügen…") { store.addSource() }
                }
                Section("Aufbewahrung") {
                    Picker("Aufbewahrung", selection: $store.retention) {
                        Text("Ausgewogen").tag(RetentionPreset.balanced)
                        Text("Platzsparend").tag(RetentionPreset.spaceSaving)
                        Text("Maximum").tag(RetentionPreset.maximum)
                        if store.hasCustomRetention { Text("Eigene").tag(RetentionPreset.custom) }
                    }
                    Text(
                        "Backups werden manuell gestartet. Automatische Zeitpläne folgen im nächsten Entwicklungsblock."
                    )
                    .foregroundStyle(.secondary)
                }
                if let message = store.connection.message { Text(message) }
                if store.localError { Text("Eingaben ungültig. Prüfe Namen, Quellen und Speicherziel.") }
            }.formStyle(.grouped)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(
                    store.connection.busy)
                Spacer()
                Button("Speichern") { store.save { dismiss() } }.buttonStyle(.borderedProminent)
                    .disabled(store.name.isEmpty || store.connection.busy)
                    .keyboardShortcut(.defaultAction)
            }.padding()
        }.frame(minWidth: 560, minHeight: 400)
            .interactiveDismissDisabled(store.connection.busy)
    }
}

#Preview {
    let connection = PreviewData.connection()
    if let plan = connection.state?.configuration?.plans.first {
        PlanEditorView().environment(PlanEditorStore(plan: plan, connection: connection))
    }
}
