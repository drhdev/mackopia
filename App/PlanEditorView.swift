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
                                .help("Quelle entfernen").accessibilityLabel(Text("Quelle entfernen")).disabled(
                                    store.sources.count <= 1)
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
                }
                Section("Zeitplan") {
                    Picker("Automatisch sichern", selection: $store.schedule) {
                        if store.hasCustomSchedule {
                            Text("Bestehende Termine beibehalten").tag(PlanEditorStore.Schedule.custom)
                        }
                        Text("Nur manuell").tag(PlanEditorStore.Schedule.manual)
                        Text("In regelmäßigen Abständen").tag(PlanEditorStore.Schedule.interval)
                        Text("Täglich").tag(PlanEditorStore.Schedule.daily)
                    }
                    if store.schedule == .interval {
                        Stepper(value: $store.minutes, in: 1...10080) {
                            LabeledContent("Abstand in Minuten", value: store.minutes.formatted())
                        }
                    }
                    if store.schedule == .daily {
                        DatePicker("Uhrzeit", selection: $store.time, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Beim Anschließen des Laufwerks sichern", isOn: $store.onMount)
                    Toggle("Verpasste Backups nachholen", isOn: $store.catchUp)
                    Toggle("Nur mit Netzteil sichern", isOn: $store.requiresACPower)
                    Toggle("Laufwerk nach erfolgreichem Backup auswerfen", isOn: $store.eject).disabled(!store.canEject)
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
