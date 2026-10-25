import BackupDomain
import QuickLook
import SwiftUI

struct RestoreView: View {
    @Environment(RestoreStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack {
            HStack {
                Picker("Speicherziel", selection: $store.repositoryID) {
                    ForEach(store.repositories) { Text($0.name).tag(Optional($0.id)) }
                }.onChange(of: store.repositoryID) { _, _ in store.load() }.disabled(!store.canBrowse)
                Button("Aktualisieren") { store.load() }.disabled(!store.canBrowse)
                Button("Wiederherstellungs-Kit…") {
                    RecoveryKit.printKit(connection: store.connection, repositoryID: store.repositoryID)
                }
                .disabled(store.repositoryID == nil)
            }
            TextField("Plan, Quelle oder Rechner filtern", text: $store.filter)
                .textFieldStyle(.roundedBorder)
            Table(store.filteredSnapshots, selection: $store.selectedSnapshotID, sortOrder: $store.sortOrder) {
                TableColumn("Datum", value: \.date) { Text(RestoreStore.date($0)) }
                TableColumn("Quelle", value: \.sourcePath)
                TableColumn("Rechner", value: \.host)
                TableColumn("Größe", value: \.bytes) { Text($0.bytes, format: .byteCount(style: .file)) }
                TableColumn("Dateien", value: \.files) { Text($0.files, format: .number) }
                TableColumn("Aufbewahrung") {
                    Text($0.retention.count, format: .number).help("Anzahl der Aufbewahrungsregeln")
                }
                TableColumn("Beschreibung", value: \.description)
                TableColumn("Pin") { snapshot in
                    if !snapshot.pins.isEmpty { Label("Fixiert", systemImage: "pin") }
                }
                TableColumn("Status") { snapshot in
                    if snapshot.isIncomplete {
                        Label("Unvollständiges Backup", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            .onChange(of: store.selectedSnapshotID) { _, _ in store.openSnapshot() }
            .disabled(!store.canBrowse)
            .contextMenu {
                Button("Beschreibung und Pin…") { store.editMetadata() }.disabled(store.selectedSnapshotID == nil)
                Button("Wiederherstellen…") { store.showRestore = true }.disabled(store.selectedSnapshotID == nil)
            }
            if store.selectedSnapshotID != nil {
                HStack {
                    Button("Übergeordneten Ordner öffnen", systemImage: "arrow.up") {
                        store.browse(Array(store.components.dropLast()))
                    }
                    .help("Übergeordneten Ordner öffnen").accessibilityLabel(Text("Übergeordneten Ordner öffnen"))
                    .disabled(store.components.isEmpty || !store.canBrowse)
                    Text(store.components.joined(separator: "/")).lineLimit(1).truncationMode(.middle)
                    TextField("Dateinamen suchen", text: $store.query).onSubmit { store.search() }
                    Button("Suchen") { store.search() }.disabled(store.query.isEmpty || !store.canBrowse)
                }
                if store.showingSearch {
                    if store.searchLimited {
                        Text("Suche begrenzt. Öffne einen Ordner, um weiterzusuchen.").foregroundStyle(.secondary)
                    }
                    List(store.matches) { match in
                        Button {
                            store.browse(match.isDirectory ? match.components : Array(match.components.dropLast()))
                        } label: {
                            Label(
                                match.components.joined(separator: "/"),
                                systemImage: match.isDirectory ? "folder" : "doc")
                        }.buttonStyle(.plain)
                    }
                } else {
                    List(store.entries, selection: $store.selectedEntry) { entry in
                        HStack {
                            Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                            Spacer()
                            if !entry.isDirectory {
                                Text(entry.bytes, format: .byteCount(style: .file)).foregroundStyle(.secondary)
                            }
                        }.tag(entry.name)
                            .contextMenu {
                                if entry.isDirectory {
                                    Button("Öffnen") { store.browse(store.components + [entry.name]) }
                                }
                                Button("Wiederherstellen…") {
                                    store.selectedEntry = entry.name; store.showRestore = true
                                }
                                if !entry.isDirectory {
                                    Button("Schnellvorschau") {
                                        store.selectedEntry = entry.name; store.preview()
                                    }
                                }
                            }
                    }.onKeyPress(.return) {
                        store.openEntry(); return .handled
                    }
                    .onKeyPress(.space) {
                        store.preview(); return .handled
                    }.disabled(!store.canBrowse)
                }
                HStack {
                    Button("Beschreibung und Pin…") { store.editMetadata() }.disabled(!store.canBrowse)
                    Button("Öffnen") { store.openEntry() }.disabled(
                        !store.canBrowse || store.selectedFile || store.selectedEntry == nil)
                    Button("Schnellvorschau") { store.preview() }.disabled(!store.canBrowse || !store.selectedFile)
                    Button("Wiederherstellen…") { store.showRestore = true }.disabled(!store.canBrowse)
                }
            } else if store.snapshots.isEmpty && !store.connection.busy {
                ContentUnavailableView(
                    "Keine Backups gefunden", systemImage: "clock.arrow.circlepath",
                    description: Text("Wähle ein Speicherziel und aktualisiere die Liste."))
            }
            RestoreProgressView()
            if store.connection.busy {
                HStack {
                    ProgressView(); Button("Abbrechen") { store.cancel() }
                }
            }
        }.padding()
            .task { if store.snapshots.isEmpty { store.load() } }
            .sheet(isPresented: $store.showMetadata) { SnapshotMetadataSheet().environment(store) }
            .sheet(isPresented: $store.showRestore) { RestoreSheet().environment(store) }
            .quickLookPreview($store.previewURL)
            .onChange(of: store.connection.state?.restore?.phase) { _, _ in store.updatePreview() }
            .onChange(of: store.previewURL) { old, value in if old != nil && value == nil { store.clearPreview() } }
            .onDisappear { store.dismissPreview() }
    }
}

#Preview("Backups") { RestoreView().environment(RestorePreviewData.store()) }
#Preview("Empty") { RestoreView().environment(RestorePreviewData.store(empty: true)) }
#Preview("Running") { RestoreView().environment(RestorePreviewData.store(phase: .running)) }
#Preview("Failed") { RestoreView().environment(RestorePreviewData.store(phase: .failed)) }
#Preview("Offline") { RestoreView().environment(RestorePreviewData.store(offline: true)) }
