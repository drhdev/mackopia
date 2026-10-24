import BackupDomain
import Foundation
import Synchronization
import Testing

@testable import Persistence

final class MemoryConfigFiles: ConfigFileSystem, ConfigFileAccess, Sendable {
    struct State {
        var primary: Data?
        var backup: Data?
        var pauses: Data?
        var failingWrite: ConfigFile?
        var writes: [ConfigFile] = []
        var unavailable = false
    }
    let state = Mutex(State())

    func withLock<T>(_ operation: (any ConfigFileAccess) throws -> T) throws -> T {
        if state.withLock({ $0.unavailable }) { throw CocoaError(.fileReadNoPermission) }
        return try operation(self)
    }

    func read(_ file: ConfigFile) throws -> Data? {
        state.withLock {
            switch file {
            case .primary: $0.primary
            case .backup: $0.backup
            case .pauses: $0.pauses
            }
        }
    }

    func replace(_ file: ConfigFile, with data: Data) throws {
        try state.withLock {
            if $0.failingWrite == file { throw CocoaError(.fileWriteOutOfSpace) }
            $0.writes.append(file)
            switch file {
            case .primary: $0.primary = data;
            case .backup: $0.backup = data
            case .pauses: $0.pauses = data
            }
        }
    }
}

struct ConfigStoreTests {
    private func configuration(_ name: String = "Test") throws -> BackupConfiguration {
        try BackupConfiguration(repositories: [
            Repository(
                name: name, kind: .filesystem(path: "/Test", volume: nil),
                identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
        ])
    }

    @Test func firstRunRequiresLoadAndSecondSaveBacksUpPreviousBytes() async throws {
        let files = MemoryConfigFiles()
        let codec = try ConfigCodec()
        let store = ConfigStore(files: files, codec: codec)
        let first = try configuration()
        await #expect(throws: ConfigStoreError.notLoaded) { try await store.save(first) }
        #expect(try await store.load() == .loaded(BackupConfiguration()))
        try await store.save(first)
        #expect(files.state.withLock { $0.backup == nil && $0.writes == [.primary] })
        let previous = files.state.withLock { $0.primary }
        let second = try configuration("Changed")
        try await store.save(second)
        #expect(files.state.withLock { $0.backup == previous && $0.writes == [.primary, .backup, .primary] })
        #expect(try await store.load() == .loaded(second))
    }

    @Test func damagedPrimaryDoesNotAutoRecoverOrOverwriteBackup() async throws {
        let files = MemoryConfigFiles()
        let codec = try ConfigCodec()
        let saved = try configuration()
        let bytes = try codec.encode(saved)
        files.state.withLock {
            $0.primary = Data("broken".utf8); $0.backup = bytes
        }
        let store = ConfigStore(files: files, codec: codec)
        #expect(try await store.load() == .safeMode(.invalidConfiguration))
        await #expect(throws: ConfigStoreError.safeMode) { try await store.save(saved) }
        #expect(files.state.withLock { $0.writes.isEmpty && $0.backup == bytes })
        #expect(try await store.restoreBackup() == saved)
        #expect(files.state.withLock { $0.primary == bytes && $0.backup == bytes && $0.writes == [.primary] })
        #expect(try await store.load() == .loaded(saved))
    }

    @Test func missingPrimaryWithBackupAndFutureVersionRequireExplicitRecovery() async throws {
        let files = MemoryConfigFiles()
        let codec = try ConfigCodec()
        let backup = try codec.encode(BackupConfiguration())
        files.state.withLock { $0.backup = backup }
        let store = ConfigStore(files: files, codec: codec)
        #expect(try await store.load() == .safeMode(.invalidConfiguration))
        files.state.withLock { $0.primary = Data(#"{"schemaVersion":99}"#.utf8) }
        #expect(try await store.load() == .safeMode(.unsupportedVersion))
        #expect(files.state.withLock { $0.writes.isEmpty })
    }

    @Test func failedBackupAndFailedPrimaryWritesPreserveRecoverableConfiguration() async throws {
        for failure in [ConfigFile.backup, .primary] {
            let files = MemoryConfigFiles()
            let codec = try ConfigCodec()
            let previous = try codec.encode(configuration())
            files.state.withLock {
                $0.primary = previous; $0.failingWrite = failure
            }
            let store = ConfigStore(files: files, codec: codec)
            _ = try await store.load()
            await #expect(throws: ConfigStoreError.storageUnavailable) { try await store.save(configuration("New")) }
            #expect(files.state.withLock { $0.primary == previous })
            if failure == .primary { #expect(files.state.withLock { $0.backup == previous }) }
            await #expect(throws: ConfigStoreError.safeMode) { try await store.save(configuration()) }
        }
    }

    @Test func externalChangesAndLateBackupsPreventLostUpdates() async throws {
        for addBackup in [false, true] {
            let files = MemoryConfigFiles()
            let codec = try ConfigCodec()
            let store = ConfigStore(files: files, codec: codec)
            _ = try await store.load()
            let external = try codec.encode(configuration("External"))
            files.state.withLock { if addBackup { $0.backup = external } else { $0.primary = external } }
            await #expect(throws: ConfigStoreError.storageChanged) { try await store.save(configuration()) }
            #expect(files.state.withLock { $0.writes.isEmpty })
        }
    }

    @Test func absentOrInvalidRecoveryAndStorageFailureRemainSafe() async throws {
        let files = MemoryConfigFiles()
        let store = ConfigStore(files: files, codec: try ConfigCodec())
        await #expect(throws: ConfigStoreError.noBackup) { try await store.restoreBackup() }
        files.state.withLock { $0.backup = Data("broken".utf8) }
        await #expect(throws: ConfigStoreError.invalidConfiguration) { try await store.restoreBackup() }
        #expect(files.state.withLock { $0.writes.isEmpty })
        files.state.withLock { $0.unavailable = true }
        #expect(try await store.load() == .safeMode(.storageUnavailable))
    }

    @Test func migrationIsInMemoryUntilSaveAndBacksUpOriginalSchema() async throws {
        let files = MemoryConfigFiles()
        let configuration = try configuration()
        let original = try ConfigCodec().encode(configuration)
        files.state.withLock { $0.primary = original }
        let migration = ConfigMigration(fromVersion: 1) { data in
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            json["schemaVersion"] = 2
            return try JSONSerialization.data(withJSONObject: json)
        }
        let store = ConfigStore(files: files, codec: try ConfigCodec(currentVersion: 2, migrations: [migration]))
        #expect(try await store.load() == .loaded(configuration))
        #expect(files.state.withLock { $0.primary == original && $0.writes.isEmpty })
        try await store.save(configuration)
        #expect(files.state.withLock { $0.backup == original && $0.primary != original })
    }

    @Test func cancelledOperationsNeverTouchStorage() async throws {
        let files = MemoryConfigFiles()
        let store = ConfigStore(files: files, codec: try ConfigCodec())
        let value = try configuration()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try Task.checkCancellation() }
            await #expect(throws: CancellationError.self) { try await store.load() }
            await #expect(throws: CancellationError.self) { try await store.save(value) }
            await #expect(throws: CancellationError.self) { try await store.restoreBackup() }
        }
        await task.value
        #expect(files.state.withLock { $0.primary == nil && $0.backup == nil && $0.writes.isEmpty })
    }
}
