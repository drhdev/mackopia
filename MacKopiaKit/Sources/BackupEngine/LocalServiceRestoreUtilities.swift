import BackupDomain
import Darwin
import Foundation

extension LocalBackupService {
    public func editSnapshot(repositoryID: UUID, snapshotID: String, description: String, pinned: Bool) async throws {
        try RestoreSelection.validate(snapshotID: snapshotID, components: [])
        guard description.utf8.count <= 4096, !description.utf8.contains(0) else {
            throw LocalServiceIssue.invalidRequest
        }
        try availableForMutation()
        let state = try await withRestoreSession(repositoryID: repositoryID, destination: nil) { service in
            let browser = RestoreBrowser(service: service)
            guard let previous = try await browser.snapshots().first(where: { $0.id == snapshotID }) else {
                throw LocalServiceIssue.invalidRequest
            }
            let original = try await browser.resolve(snapshotID: snapshotID, components: [])
            let changed = try await service.editSnapshot(id: snapshotID, description: description, pinned: pinned)
            guard changed.rootID == original.id,
                Set(previous.pins).subtracting(["mackopia-user"]).isSubset(of: Set(changed.pins ?? []))
            else { throw LocalServiceIssue.invalidRequest }
            var state = RestoreState(repositoryID: repositoryID)
            state.snapshots = try await browser.snapshots()
            return state
        }
        restoreState = state; changed()
    }

    public func searchRestore(repositoryID: UUID, snapshotID: String, query: String) async throws {
        try RestoreSelection.validate(snapshotID: snapshotID, components: [])
        guard !query.isEmpty, query.utf8.count <= 256, !query.utf8.contains(0) else {
            throw LocalServiceIssue.invalidRequest
        }
        try availableForMutation()
        let result = try await withRestoreSession(repositoryID: repositoryID, destination: nil) { service in
            try await RestoreBrowser(service: service).search(snapshotID: snapshotID, query: query)
        }
        var state = RestoreState(repositoryID: repositoryID)
        state.snapshotID = snapshotID; state.matches = result.0; state.searchLimited = result.1
        restoreState = state; changed()
    }

    public func previewRestore(repositoryID: UUID, snapshotID: String, components: [String]) throws {
        guard !components.isEmpty else { throw LocalServiceIssue.invalidRequest }
        try availableForMutation()
        try clearRestorePreview()
        try RestorePreviewCache.removeAbandonedSessions(home: home)
        let root = try RestorePreviewCache.prepare(home: home)
        let session = root.appendingPathComponent(UUID().uuidString)
        guard mkdir(session.path, 0o700) == 0 else { throw LocalServiceIssue.destination }
        previewDirectory = session
        do {
            let source = try BackupSource(path: session.path, volume: volume(session))
            try restore(
                repositoryID: repositoryID, snapshotID: snapshotID, components: components,
                destination: source, preview: true)
        } catch {
            try? clearRestorePreview()
            throw error
        }
    }

    public func clearRestorePreview() throws {
        guard restoreTask == nil else { throw LocalServiceIssue.busy }
        if let directory = previewDirectory {
            try FileManager.default.removeItem(at: directory)
            previewDirectory = nil
        }
        if restoreState?.preview == true { restoreState = nil; changed() }
    }
}
