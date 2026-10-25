import SwiftUI

struct SnapshotMetadataSheet: View {
    @Environment(RestoreStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var store = store
        Form {
            TextField("Beschreibung", text: $store.snapshotDescription, axis: .vertical)
            Toggle("Backup dauerhaft aufbewahren", isOn: $store.pinned)
            Text("Automatische Sicherheits-Pins bleiben erhalten.").foregroundStyle(.secondary)
            HStack {
                Button("Abbrechen", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Speichern") { store.saveMetadata() }.buttonStyle(.borderedProminent)
                    .disabled(!store.canBrowse || store.snapshotDescription.utf8.count > 4096)
            }
        }.formStyle(.grouped).padding().frame(minWidth: 480, minHeight: 240)
    }
}

#Preview { SnapshotMetadataSheet().environment(RestorePreviewData.store()) }
