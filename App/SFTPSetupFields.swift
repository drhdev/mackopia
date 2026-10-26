import SwiftUI

struct SFTPSetupFields: View {
    @Environment(LocalSetupStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Group {
            TextField("SFTP-Server", text: $store.sftpHost).disabled(store.credentialRepository != nil)
            TextField("Port", text: $store.sftpPort).disabled(store.credentialRepository != nil)
            TextField("SFTP-Benutzername", text: $store.sftpUsername).disabled(store.credentialRepository != nil)
            TextField("SFTP-Ordner", text: $store.sftpPath).disabled(store.credentialRepository != nil)
            TextField("Öffentlicher Host-Key", text: $store.sftpHostKey)
            Text(
                "Übernimm den öffentlichen Host-Key vom Serverbetreiber über einen vertrauenswürdigen Weg (Typ und Base64-Schlüssel, ohne Kommentar). Vergleiche den Fingerprint vor der Freigabe."
            )
            .foregroundStyle(.secondary)
            if !store.sftpFingerprint.isEmpty {
                LabeledContent("Host-Key-Fingerprint", value: store.sftpFingerprint).textSelection(.enabled)
                Toggle(
                    "Host-Key geprüft und freigeben",
                    isOn: Binding(
                        get: { store.sftpConfirmedKey == store.sftpHostKey },
                        set: { store.sftpConfirmedKey = $0 ? store.sftpHostKey : "" }))
            }
            DisclosureGroup("Privaten SSH-Schlüssel einfügen") {
                TextEditor(text: $store.sftpPrivateKey)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 96)
                    .accessibilityLabel("Privater SSH-Schlüssel")
                    .privacySensitive()
            }
            SecureField("Schlüssel-Passphrase (optional)", text: $store.sftpPassphrase)
            Text(
                "Füge einen privaten SSH-Schlüssel ein. Passphrase-geschützte RSA-PEM-Schlüssel werden nur im Arbeitsspeicher entschlüsselt; verschlüsselte OpenSSH-Schlüssel und SSH-Passwortanmeldung werden noch nicht unterstützt. Der Schlüssel wird ausschließlich im Schlüsselbund gespeichert."
            )
            .foregroundStyle(.secondary)
        }
        .onChange(of: store.sftpHostKey) { _, _ in store.sftpConfirmedKey = "" }
        .onChange(of: store.sftpHost) { _, _ in store.sftpConfirmedKey = "" }
        .onChange(of: store.sftpPort) { _, _ in store.sftpConfirmedKey = "" }
    }
}

#Preview {
    SFTPSetupFields().environment(LocalSetupStore(connection: AgentConnection(preview: true)))
}
