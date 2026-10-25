import AgentProtocol
import AppKit
import BackupDomain
import Observation

@Observable @MainActor
final class RestoreStore {
    let connection: AgentConnection
    var repositoryID: UUID?
    var snapshots: [RestoreSnapshot] = []
    var selectedSnapshotID: String?
    var selectedEntry: String?
    var components: [String] = []
    var entries: [RestoreEntry] = []
    var sortOrder = [KeyPathComparator(\RestoreSnapshot.date, order: .reverse)]
    var filter = ""
    var query = ""
    var matches: [RestoreSearchMatch] = []
    var searchLimited = false
    var showingSearch = false
    var showRestore = false
    var showMetadata = false
    var snapshotDescription = ""
    var pinned = false
    var destination: BackupSource?
    var previewURL: URL?

    init(connection: AgentConnection) { self.connection = connection }
    var repositories: [Repository] { connection.state?.configuration?.repositories ?? [] }
    var filteredSnapshots: [RestoreSnapshot] {
        snapshots.filter { snapshot in
            let plans =
                connection.state?.configuration?.plans.filter {
                    $0.repositoryID == repositoryID && $0.sources.contains { $0.path == snapshot.sourcePath }
                }.map(\.name) ?? []
            return filter.isEmpty
                || ([snapshot.sourcePath, snapshot.user, snapshot.host] + plans)
                    .contains { $0.localizedCaseInsensitiveContains(filter) }
        }.sorted(using: sortOrder)
    }
    var running: Bool { connection.state?.restore?.phase == .running }
    var canBrowse: Bool {
        connection.connected && !connection.busy && !running && connection.state?.activePlanID == nil
    }
    var selectedComponents: [String] { components + (selectedEntry.map { [$0] } ?? []) }
    var selectedFile: Bool { entries.first { $0.name == selectedEntry }?.isDirectory == false }
    var selectionLabel: String { selectedEntry ?? components.last ?? String(localized: "Gesamtes Backup") }

    func load() {
        if repositoryID == nil { repositoryID = repositories.first?.id }
        selectedSnapshotID = nil; components = []; entries = []; matches = []; showingSearch = false
        guard let repositoryID else { return }
        connection.send(.browse(repositoryID: repositoryID, snapshotID: nil, components: [])) { [weak self] in
            guard let self else { return }; snapshots = connection.state?.restore?.snapshots ?? []
        }
    }
    func openSnapshot() {
        selectedEntry = nil; components = []; showingSearch = false
        browse([])
    }
    func browse(_ path: [String]) {
        guard let repositoryID, let selectedSnapshotID else { return }
        connection.send(.browse(repositoryID: repositoryID, snapshotID: selectedSnapshotID, components: path)) {
            [weak self] in
            guard let self, let state = connection.state?.restore else { return }
            components = state.components; entries = state.entries; selectedEntry = nil; showingSearch = false
        }
    }
    func openEntry() {
        guard let entry = entries.first(where: { $0.name == selectedEntry }), entry.isDirectory else { return }
        browse(components + [entry.name])
    }
    func search() {
        guard let repositoryID, let selectedSnapshotID, !query.isEmpty else { return }
        connection.send(.searchRestore(repositoryID: repositoryID, snapshotID: selectedSnapshotID, query: query)) {
            [weak self] in
            guard let self, let state = connection.state?.restore else { return }
            matches = state.matches; searchLimited = state.searchLimited; showingSearch = true
        }
    }
    func editMetadata() {
        guard let snapshot = snapshots.first(where: { $0.id == selectedSnapshotID }) else { return }
        snapshotDescription = snapshot.description; pinned = snapshot.pins.contains("mackopia-user");
        showMetadata = true
    }
    func saveMetadata() {
        guard let repositoryID, let selectedSnapshotID else { return }
        connection.send(
            .editSnapshot(
                repositoryID: repositoryID, snapshotID: selectedSnapshotID,
                description: snapshotDescription, pinned: pinned)
        ) { [weak self] in
            guard let self else { return }
            showMetadata = false; load()
        }
    }
    func prepareDestination() async {
        guard destination == nil else { return }
        destination = await connection.defaultRestoreDestination()
    }
    func chooseDestination() { connection.chooseDirectory { [weak self] in self?.destination = $0 } }
    func startRestore() {
        guard let repositoryID, let selectedSnapshotID, let destination else { return }
        connection.send(
            .restore(
                repositoryID: repositoryID, snapshotID: selectedSnapshotID,
                components: selectedComponents, destination: destination)
        ) { [weak self] in self?.showRestore = false }
    }
    func cancel() {
        if let id = connection.state?.restore?.operationID, running {
            connection.send(.cancelRestore(id))
        } else {
            connection.cancelOperation()
        }
    }
    func preview() {
        guard selectedFile, let repositoryID, let selectedSnapshotID else { return }
        connection.send(
            .previewRestore(repositoryID: repositoryID, snapshotID: selectedSnapshotID, components: selectedComponents))
    }
    func updatePreview() {
        guard let state = connection.state?.restore, state.preview, state.phase == .succeeded,
            let path = state.destination
        else { return }
        previewURL = URL(fileURLWithPath: path)
    }
    func clearPreview() { connection.send(.clearRestorePreview) }
    func dismissPreview() {
        previewURL = nil
        guard connection.state?.restore?.preview == true else { return }
        if running, let id = connection.state?.restore?.operationID {
            connection.send(.cancelRestore(id)) { [weak self] in self?.clearPreview() }
        } else {
            clearPreview()
        }
    }
    func showInFinder() {
        guard let path = connection.state?.restore?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
    static func date(_ snapshot: RestoreSnapshot) -> String {
        let date =
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(snapshot.date))
            ?? (try? Date.ISO8601FormatStyle().parse(snapshot.date))
        return date?.formatted(date: .abbreviated, time: .shortened) ?? snapshot.date
    }
    var phaseLabel: String {
        switch connection.state?.restore?.phase {
        case .running: String(localized: "Wiederherstellung läuft")
        case .succeeded: String(localized: "Wiederherstellung abgeschlossen")
        case .cancelled: String(localized: "Wiederherstellung abgebrochen")
        case .failed: String(localized: "Wiederherstellung fehlgeschlagen")
        default: ""
        }
    }
}
