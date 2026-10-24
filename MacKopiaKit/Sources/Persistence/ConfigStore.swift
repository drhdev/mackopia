import BackupDomain
import Foundation

package enum ConfigLoadResult: Sendable, Equatable {
    case loaded(BackupConfiguration)
    case safeMode(ConfigStoreError)
}

/// Agent-owned persistence; never instantiate from an app view or write configuration through XPC directly.
package actor ConfigStore {
    package nonisolated let pauseStore: BackupPauseStore
    private let files: any ConfigFileSystem
    private let codec: ConfigCodec
    private var state: ConfigLoadResult?
    private var loadedBytes: Data?

    package init(directory: URL) throws {
        files = try LocalConfigFileSystem(directory: directory)
        pauseStore = BackupPauseStore(files: files)
        codec = try ConfigCodec()
    }

    init(files: any ConfigFileSystem, codec: ConfigCodec) {
        pauseStore = BackupPauseStore(files: files)
        self.files = files
        self.codec = codec
    }

    /// Returns the latest state accepted by this store; safe mode never authorizes a job.
    package func currentConfiguration() throws -> BackupConfiguration {
        try Task.checkCancellation()
        guard let state else { throw ConfigStoreError.notLoaded }
        guard case .loaded(let configuration) = state else { throw ConfigStoreError.safeMode }
        return configuration
    }

    package func load() throws -> ConfigLoadResult {
        try Task.checkCancellation()
        do {
            let (configuration, bytes) = try files.withLock { access in
                let bytes = try access.read(.primary)
                if let bytes { return (try codec.decode(bytes), Optional(bytes)) }
                guard try access.read(.backup) == nil else { throw ConfigStoreError.invalidConfiguration }
                return (try BackupConfiguration(), nil)
            }
            loadedBytes = bytes
            state = .loaded(configuration)
        } catch is CancellationError {
            state = nil
            loadedBytes = nil
            throw CancellationError()
        } catch {
            loadedBytes = nil
            state = .safeMode(Self.classify(error))
        }
        guard let state else { throw ConfigStoreError.notLoaded }
        return state
    }

    package func save(_ configuration: BackupConfiguration) throws {
        try Task.checkCancellation()
        guard let state else { throw ConfigStoreError.notLoaded }
        guard case .loaded = state else { throw ConfigStoreError.safeMode }
        let data = try codec.encode(configuration)
        do {
            try files.withLock { access in
                guard try access.read(.primary) == loadedBytes else { throw ConfigStoreError.storageChanged }
                if let loadedBytes {
                    try access.replace(.backup, with: loadedBytes)
                } else if try access.read(.backup) != nil {
                    throw ConfigStoreError.storageChanged
                }
                try access.replace(.primary, with: data)
            }
            loadedBytes = data
            self.state = .loaded(configuration)
        } catch {
            // A failed transaction may have replaced a file before durability failed. Reload before further writes.
            self.state = .safeMode(Self.classify(error))
            if error is CancellationError { throw CancellationError() }
            throw Self.classify(error)
        }
    }

    /// Call only after the user explicitly chooses configuration recovery. Never auto-promote a backup on load.
    package func restoreBackup() throws -> BackupConfiguration {
        try Task.checkCancellation()
        do {
            let (configuration, bytes) = try files.withLock { access in
                guard let bytes = try access.read(.backup) else { throw ConfigStoreError.noBackup }
                let configuration = try codec.decode(bytes)
                let canonical = try codec.encode(configuration)
                try access.replace(.primary, with: canonical)
                return (configuration, canonical)
            }
            loadedBytes = bytes
            state = .loaded(configuration)
            return configuration
        } catch {
            state = .safeMode(Self.classify(error))
            if error is CancellationError { throw CancellationError() }
            throw Self.classify(error)
        }
    }

    private static func classify(_ error: any Error) -> ConfigStoreError {
        (error as? ConfigStoreError) ?? .storageUnavailable
    }
}
