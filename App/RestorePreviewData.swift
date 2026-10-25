import BackupDomain
import Foundation

@MainActor
enum RestorePreviewData {
    static func store(phase: RestoreState.Phase = .idle, empty: Bool = false, offline: Bool = false) -> RestoreStore {
        let connection = PreviewData.connection()
        let store = RestoreStore(connection: connection)
        guard let repositoryID = connection.state?.configuration?.repositories.first?.id else { return store }
        store.repositoryID = repositoryID
        let snapshotID = String(repeating: "a", count: 32)
        if !empty {
            store.snapshots = [
                RestoreSnapshot(
                    id: snapshotID, sourcePath: "/example/Documents",
                    user: "example", host: "Other Mac", date: "2026-10-25T08:00:00Z",
                    bytes: 4_000_000, files: 12, retention: ["daily-1"], pins: [])
            ]
            store.selectedSnapshotID = snapshotID
            store.entries = [
                RestoreEntry(name: "Documents", isDirectory: true, bytes: 0),
                RestoreEntry(name: "Example.pdf", isDirectory: false, bytes: 4096),
            ]
        }
        var state = RestoreState(repositoryID: repositoryID)
        state.snapshots = store.snapshots; state.snapshotID = store.selectedSnapshotID; state.entries = store.entries
        state.phase = phase
        if phase != .idle {
            state.operationID = UUID(); state.bytes = 4096; state.files = 1;
            state.destination = "/example/Downloads/Restore"
        }
        connection.state = LocalServiceState(configuration: connection.state?.configuration, restore: state)
        connection.connected = !offline
        return store
    }
}
