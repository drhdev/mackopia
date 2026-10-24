import Foundation
import Synchronization

/// Private, atomically replaced state beside config.json; shares its file and lock protections.
package final class BackupPauseStore: BackupWorkStoring {
    private struct Document: Codable {
        let version: Int
        let pauses: [StoredBackupPause]
        let work: [StoredBackupWork]?
    }
    private struct State {
        var loaded = false
        var bytes: Data?
        var pauses: [StoredBackupPause] = []
        var work: [StoredBackupWork] = []
    }
    private let files: any ConfigFileSystem
    private let state = Mutex(State())

    package convenience init(directory: URL) throws {
        self.init(files: try LocalConfigFileSystem(directory: directory))
    }

    init(files: any ConfigFileSystem) { self.files = files }

    /// Each runtime keeps its own comparison baseline, including when ConfigStore is shared.
    package func makeSession() -> BackupPauseStore { BackupPauseStore(files: files) }

    package func load() throws -> [StoredBackupPause] {
        do {
            return try state.withLock { state in
                state.loaded = false
                let (pauses, work, bytes) = try files.withLock { access in
                    guard let bytes = try access.read(.pauses) else {
                        return ([StoredBackupPause](), [StoredBackupWork](), Optional<Data>.none)
                    }
                    guard bytes.count <= ConfigCodec.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
                    let document: Document
                    do { document = try JSONDecoder().decode(Document.self, from: bytes) } catch {
                        throw ConfigStoreError.invalidConfiguration
                    }
                    guard document.version == 1 || document.version == 2 else {
                        throw ConfigStoreError.unsupportedVersion
                    }
                    guard document.version != 2 || document.work != nil,
                        document.version != 1 || document.work == nil
                    else { throw ConfigStoreError.invalidConfiguration }
                    try StoredBackupPause.validate(document.pauses)
                    let work = document.work ?? []
                    try StoredBackupWork.validate(work)
                    return (document.pauses, work, Optional(bytes))
                }
                state.bytes = bytes
                state.loaded = true
                state.pauses = pauses
                state.work = work
                return pauses
            }
        } catch {
            if error is CancellationError { throw CancellationError() }
            throw (error as? ConfigStoreError) ?? ConfigStoreError.storageUnavailable
        }
    }

    package func save(_ pauses: [StoredBackupPause]) throws {
        try StoredBackupPause.validate(pauses)
        try state.withLock { state in
            try save(pauses: pauses, work: state.work, state: &state)
        }
    }

    package func loadWork() throws -> [StoredBackupWork] {
        try state.withLock { state in
            guard state.loaded else { throw ConfigStoreError.notLoaded }
            return state.work
        }
    }

    package func saveWork(_ work: [StoredBackupWork]) throws {
        try StoredBackupWork.validate(work)
        try state.withLock { state in
            try save(pauses: state.pauses, work: work, state: &state)
        }
    }

    private func save(pauses: [StoredBackupPause], work: [StoredBackupWork], state: inout State) throws {
        guard state.loaded else { throw ConfigStoreError.notLoaded }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let sorted = pauses.sorted { ($0.planID?.uuidString ?? "") < ($1.planID?.uuidString ?? "") }
        let bytes = try encoder.encode(Document(version: 2, pauses: sorted, work: work))
        guard bytes.count <= ConfigCodec.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
        do {
            try files.withLock { access in
                guard try access.read(.pauses) == state.bytes else { throw ConfigStoreError.storageChanged }
                if bytes != state.bytes { try access.replace(.pauses, with: bytes) }
            }
            state.bytes = bytes
            state.pauses = pauses
            state.work = work
        } catch {
            state.loaded = false
            throw (error as? ConfigStoreError) ?? ConfigStoreError.storageUnavailable
        }
    }
}
