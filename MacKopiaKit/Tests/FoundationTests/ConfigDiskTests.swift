import BackupDomain
import Darwin
import Foundation
import Testing

@testable import Persistence

struct ConfigDiskTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacKopia-config-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private func configuration(_ name: String) throws -> BackupConfiguration {
        try BackupConfiguration(repositories: [
            Repository(
                name: name, kind: .filesystem(path: "/Test", volume: nil),
                identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
        ])
    }

    @Test func diskRoundTripBackupRecoveryPermissionsAndTemporaryCleanup() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("State")
        let store = try ConfigStore(directory: directory)
        #expect(try await store.load() == .loaded(BackupConfiguration()))
        let first = try configuration("First")
        try await store.save(first)
        let primary = directory.appendingPathComponent("config.json")
        let oldBytes = try Data(contentsOf: primary)
        try await store.save(configuration("Second"))
        #expect(try Data(contentsOf: directory.appendingPathComponent("config.json.bak")) == oldBytes)
        let restarted = try ConfigStore(directory: directory)
        #expect(try await restarted.load() == .loaded(configurationFromDisk(primary)))
        // Overwrite in place to retain the required permissions while simulating a corrupt primary.
        let handle = try FileHandle(forWritingTo: primary)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("broken".utf8))
        try handle.close()
        #expect(try await restarted.load() == .safeMode(.invalidConfiguration))
        #expect(try await restarted.restoreBackup() == first)
        #expect(try await store.load() == .loaded(first))
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(contents) == ["config.json", "config.json.bak", ".config.lock"])
        for name in contents {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    private func configurationFromDisk(_ url: URL) throws -> BackupConfiguration {
        try ConfigCodec().decode(Data(contentsOf: url))
    }

    @Test func twoStoreInstancesCannotSilentlyOverwriteEachOther() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try ConfigStore(directory: root)
        let b = try ConfigStore(directory: root)
        _ = try await a.load()
        _ = try await b.load()
        let value = try configuration("Winner")
        try await a.save(value)
        await #expect(throws: ConfigStoreError.storageChanged) { try await b.save(configuration("Stale")) }
        #expect(try await a.load() == .loaded(value))
    }

    @Test func symlinkAndHardlinkFilesAndDirectoriesAreRejectedWithoutTargetChanges() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("Outside")
        let sentinel = Data(UUID().uuidString.utf8)
        try sentinel.write(to: outside)
        #expect(chmod(outside.path, 0o600) == 0)
        for name in ["config.json", "config.json.bak", ".config.lock"] {
            for hardlink in [false, true] {
                let directory = root.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                let target = directory.appendingPathComponent(name)
                if hardlink {
                    try FileManager.default.linkItem(at: outside, to: target)
                } else {
                    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
                }
                let store = try ConfigStore(directory: directory)
                #expect(try await store.load() == .safeMode(.unsafeStorage))
                #expect(try Data(contentsOf: outside) == sentinel)
                try FileManager.default.removeItem(at: directory)
            }
        }
        let directoryLink = root.appendingPathComponent("DirectoryLink")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        let store = try ConfigStore(directory: directoryLink)
        #expect(try await store.load() == .safeMode(.unsafeStorage))
    }

    @Test func nonregularFilesUnsafePermissionsAndOversizePrimaryFailClosed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("config.json")
        #expect(mkfifo(primary.path, 0o600) == 0)
        let store = try ConfigStore(directory: root)
        #expect(try await store.load() == .safeMode(.unsafeStorage))
        try FileManager.default.removeItem(at: primary)
        try Data("{}".utf8).write(to: primary)
        #expect(chmod(primary.path, 0o644) == 0)
        #expect(try await store.load() == .safeMode(.unsafeStorage))
        #expect(chmod(primary.path, 0o600) == 0)
        let handle = try FileHandle(forWritingTo: primary)
        try handle.truncate(atOffset: UInt64(ConfigCodec.maximumBytes + 1))
        try handle.close()
        #expect(try await store.load() == .safeMode(.invalidConfiguration))
        #expect(chmod(root.path, 0o755) == 0)
        #expect(try await store.load() == .safeMode(.unsafeStorage))
        #expect(chmod(root.path, 0o700) == 0)
    }

    @Test func substitutedBackupCannotRedirectSaveOutsideProtectedDirectory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("State")
        let store = try ConfigStore(directory: directory)
        _ = try await store.load()
        let value = try configuration("Original")
        try await store.save(value)
        let outside = root.appendingPathComponent("Outside")
        let sentinel = Data(UUID().uuidString.utf8)
        try sentinel.write(to: outside)
        let backup = directory.appendingPathComponent("config.json.bak")
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
        await #expect(throws: ConfigStoreError.unsafeStorage) { try await store.save(configuration("New")) }
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(try configurationFromDisk(directory.appendingPathComponent("config.json")) == value)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!names.contains { $0.hasSuffix(".tmp") })
    }

    @Test func heldLockPreventsConcurrentTransactions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try LocalConfigFileSystem(directory: root)
        let nested = try files.withLock { _ in
            Result { try files.withLock { _ in true } }
        }
        #expect(throws: ConfigStoreError.storageUnavailable) { try nested.get() }
        let bytes = try files.withLock { try $0.read(.primary) }
        #expect(bytes == nil)
    }
}
