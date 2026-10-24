import Foundation
import Testing

@testable import Persistence

struct BackupPauseStoreTests {
    @Test func privateAtomicRoundTripPreservesGlobalPlanAndUnavailableTimers() throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("state")
        let store = try BackupPauseStore(directory: directory)
        #expect(try store.load().isEmpty)
        let pauses = [
            StoredBackupPause(planID: nil, state: .indefinite),
            StoredBackupPause(planID: UUID(), state: .until(Date(timeIntervalSince1970: 1000))),
            StoredBackupPause(planID: UUID(), state: .timerUnavailable(until: Date(timeIntervalSince1970: 2000))),
        ]
        try store.save(pauses)
        #expect(Set(try BackupPauseStore(directory: directory).load().map(\.planID)) == Set(pauses.map(\.planID)))
        #expect(try BackupPauseStore(directory: directory).load().allSatisfy { pauses.contains($0) })
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("pauses.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") }
                == false)
    }

    @Test func competingWriterCannotOverwriteNewerPauseAndMustReload() throws {
        let files = MemoryConfigFiles()
        let first = BackupPauseStore(files: files)
        let second = BackupPauseStore(files: files)
        _ = try first.load()
        _ = try second.load()
        let pause = StoredBackupPause(planID: UUID(), state: .indefinite)
        try first.save([pause])
        #expect(throws: ConfigStoreError.storageChanged) { try second.save([]) }
        #expect(throws: ConfigStoreError.notLoaded) { try second.save([]) }
        #expect(try second.load() == [pause])
    }

    @Test func corruptFutureAndDuplicateDocumentsNeverBecomeEmptyState() throws {
        let files = MemoryConfigFiles()
        let store = BackupPauseStore(files: files)
        files.state.withLock { $0.pauses = Data("invalid".utf8) }
        #expect(throws: ConfigStoreError.invalidConfiguration) { try store.load() }
        #expect(throws: ConfigStoreError.notLoaded) { try store.save([]) }
        files.state.withLock { $0.pauses = Data(#"{"version":99,"pauses":[]}"#.utf8) }
        #expect(throws: ConfigStoreError.unsupportedVersion) { try store.load() }
        files.state.withLock { $0.pauses = nil }
        _ = try store.load()
        let pause = StoredBackupPause(planID: nil, state: .indefinite)
        #expect(throws: ConfigStoreError.invalidConfiguration) { try store.save([pause, pause]) }
        #expect(throws: ConfigStoreError.invalidConfiguration) {
            try store.save([StoredBackupPause(planID: nil, state: .until(Date(timeIntervalSince1970: .infinity)))])
        }
    }

    @Test func symlinkedPauseFileIsRejectedWithoutChangingTarget() throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("marker")
        let data = Data("private-marker".utf8)
        try data.write(to: marker)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("pauses.json"), withDestinationURL: marker)
        let store = try BackupPauseStore(directory: root)
        #expect(throws: ConfigStoreError.unsafeStorage) { try store.load() }
        #expect(try Data(contentsOf: marker) == data)
    }
}
