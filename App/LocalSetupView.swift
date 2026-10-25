import SwiftUI

struct LocalSetupView: View {
    @Environment(LocalSetupStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack {
            Form {
                Section("Lokales Speicherziel") {
                    TextField("Name", text: $store.name)
                    if let repositories = store.connection.state?.configuration?.repositories, !repositories.isEmpty {
                        Picker("Speicherziel", selection: $store.repositoryID) {
                            Text("Weiteres Speicherziel einrichten").tag(Optional<UUID>.none)
                            ForEach(repositories) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if store.repositoryID == nil {
                        Picker("Einrichtung", selection: $store.create) {
                            Text("Neu anlegen").tag(true)
                            Text("Vorhandenes verbinden").tag(false)
                        }
                        LabeledContent("Speicherziel") {
                            directoryLabel(store.destination)
                            Button("Auswählen…") { store.selectDestination() }
                        }
                        if store.create {
                            Text("Wähle einen leeren Ordner für dein neues Speicherziel.").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Quelle") {
                        directoryLabel(store.source)
                        Button("Quelle auswählen…") { store.selectSource() }
                    }
                }
                if store.repositoryID == nil {
                    Section("Backup-Passwort") {
                        SecureField("Backup-Passwort", text: $store.password)
                            .textContentType(store.create ? .newPassword : .password)
                        if store.create {
                            SecureField("Passwort bestätigen", text: $store.confirmation).textContentType(.newPassword)
                            Button("Passwort generieren") { store.generatePassword() }
                            Toggle("Passwort anzeigen", isOn: $store.revealPassword)
                            if store.revealPassword { TextField("Backup-Passwort", text: $store.password) }
                            Text("Mindestens 12 Zeichen. Bewahre dein Passwort an einem sicheren Ort auf.")
                            Text("Ohne dieses Passwort sind deine Backups unwiederbringlich verloren.")
                        }
                    }
                }
                if let message = store.connection.message { Section { Text(message).foregroundStyle(.secondary) } }
            }.formStyle(.grouped).disabled(store.connection.busy)
            HStack {
                Button("Abbrechen", role: .cancel) {
                    store.cancel(); dismiss()
                }.keyboardShortcut(.cancelAction)
                Spacer()
                if store.connection.busy { ProgressView().controlSize(.small) }
                Button("Einrichten") {
                    store.submit { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.valid || store.connection.busy)
                .keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(minWidth: 600, minHeight: 520)
        .interactiveDismissDisabled(store.connection.busy)
        .onDisappear { store.clear() }
    }
    private func directoryLabel(_ path: String) -> some View {
        Text(path.isEmpty ? String(localized: "Noch nicht ausgewählt") : path)
            .lineLimit(1).truncationMode(.middle).help(path)
    }
}

#Preview { LocalSetupView().environment(LocalSetupStore(connection: AgentConnection(preview: true))) }
