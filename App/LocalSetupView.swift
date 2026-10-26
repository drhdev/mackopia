import SwiftUI

struct LocalSetupView: View {
    @Environment(LocalSetupStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        VStack {
            Form {
                Section("Speicherziel") {
                    TextField("Name", text: $store.name).disabled(store.credentialRepository != nil)
                    if store.credentialRepository == nil,
                        let repositories = store.connection.state?.configuration?.repositories, !repositories.isEmpty
                    {
                        Picker("Speicherziel", selection: $store.repositoryID) {
                            Text("Weiteres Speicherziel einrichten").tag(Optional<UUID>.none)
                            ForEach(repositories) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if store.needsDestination {
                        if store.credentialRepository == nil {
                            Picker("Einrichtung", selection: $store.create) {
                                Text("Neu anlegen").tag(true)
                                Text("Vorhandenes verbinden").tag(false)
                            }
                            Picker("Typ", selection: $store.backend) {
                                Text("Lokales Dateisystem").tag(LocalSetupStore.Backend.filesystem)
                                Text("S3-kompatibel").tag(LocalSetupStore.Backend.s3)
                                Text("WebDAV").tag(LocalSetupStore.Backend.webDAV)
                            }
                        }
                        if store.backend == .webDAV {
                            TextField("WebDAV-URL", text: $store.webDAVURL).disabled(store.credentialRepository != nil)
                            SecureField("WebDAV-Benutzername", text: $store.webDAVUsername)
                            SecureField("WebDAV-Passwort", text: $store.webDAVPassword)
                            Text(
                                "Verwende einen eigenen WebDAV-Ordner mit HTTPS und Lese-, Schreib-, Listen- und Löschrechten. Die Einrichtung prüft den Zugang; vorhandene Backups werden beim Anlegen nicht ersetzt."
                            )
                            .foregroundStyle(.secondary)
                        } else if store.backend == .s3 {
                            TextField("HTTPS-Endpunkt", text: $store.endpoint).disabled(
                                store.credentialRepository != nil)
                            TextField("Bucket", text: $store.bucket).disabled(store.credentialRepository != nil)
                            TextField("Präfix", text: $store.prefix).disabled(store.credentialRepository != nil)
                            TextField("Region", text: $store.region).disabled(store.credentialRepository != nil)
                            SecureField("Zugriffsschlüssel", text: $store.accessKey)
                            SecureField("Geheimer Zugriffsschlüssel", text: $store.secretKey)
                            SecureField("Sitzungstoken (optional)", text: $store.sessionToken)
                            Text(
                                "Verwende einen vorhandenen Bucket und Zugangsdaten mit Lese-, Schreib-, Listen- und Löschrechten nur für das gewählte Präfix. Die Einrichtung prüft den Zugang; vorhandene Backups werden beim Anlegen nicht ersetzt."
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            LabeledContent("Speicherziel") {
                                directoryLabel(store.destination)
                                Button("Auswählen…") { store.selectDestination() }
                            }
                            if store.create {
                                Text("Wähle einen leeren Ordner für dein neues Speicherziel.").foregroundStyle(
                                    .secondary)
                            }
                        }
                    }
                    if store.credentialRepository == nil {
                        LabeledContent("Quelle") {
                            directoryLabel(store.source)
                            Button("Quelle auswählen…") { store.selectSource() }
                        }
                    }
                }
                if store.needsDestination {
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
                Button {
                    store.submit { dismiss() }
                } label: {
                    Text(
                        store.credentialRepository == nil
                            ? String(localized: "Einrichten") : String(localized: "Zugang prüfen und speichern"))
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

#Preview("S3") {
    let store: LocalSetupStore = {
        let store = LocalSetupStore(connection: AgentConnection(preview: true))
        store.backend = .s3
        store.bucket = "example-backups"
        return store
    }()
    return LocalSetupView().environment(store)
}

#Preview("WebDAV") {
    let store = LocalSetupStore(connection: AgentConnection(preview: true))
    store.backend = .webDAV
    return LocalSetupView().environment(store)
}
