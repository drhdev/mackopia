import BackupDomain
import Foundation
import Persistence
import Testing

@testable import Persistence

struct BackupWorkStoreTests {
    @Test func versionOneMigratesAndPauseEditsPreserveWorkInPrivateAtomicDocument() throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try LocalConfigFileSystem(directory: root)
        try files.withLock { try $0.replace(.pauses, with: Data(#"{"version":1,"pauses":[]}"#.utf8)) }
        let store = try BackupPauseStore(directory: root)
        #expect(try store.load().isEmpty)
        #expect(try store.loadWork().isEmpty)
        let work = item()
        try store.saveWork([work])
        let pause = StoredBackupPause(planID: work.planID, state: .indefinite)
        try store.save([pause])
        let reopened = try BackupPauseStore(directory: root)
        #expect(try reopened.load() == [pause])
        #expect(try reopened.loadWork() == [work])
        try reopened.saveWork([])
        #expect(try reopened.load() == [pause])
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("pauses.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func malformedWorkAndAmbiguousVersionsNeverBecomeAnEmptyQueue() throws {
        let files = MemoryConfigFiles()
        let store = BackupPauseStore(files: files)
        for json in [
            #"{"version":2,"pauses":[]}"#,
            #"{"version":1,"pauses":[],"work":[]}"#,
            #"{"version":2,"pauses":[],"work":[{}]}"#,
        ] {
            files.state.withLock { $0.pauses = Data(json.utf8) }
            #expect(throws: ConfigStoreError.invalidConfiguration) { try store.load() }
            #expect(throws: ConfigStoreError.notLoaded) { try store.loadWork() }
        }
        files.state.withLock { $0.pauses = nil }
        _ = try store.load()
        let work = item()
        #expect(throws: ConfigStoreError.invalidConfiguration) { try store.saveWork([work, work]) }
        #expect(throws: ConfigStoreError.invalidConfiguration) {
            try store.saveWork([work, item(planID: work.planID)])
        }
        #expect(throws: ConfigStoreError.invalidConfiguration) {
            try store.saveWork([item(date: Date(timeIntervalSince1970: .infinity))])
        }
    }

    @Test func workWriteCannotOverwriteAnotherSessionsPauseChange() throws {
        let files = MemoryConfigFiles()
        let first = BackupPauseStore(files: files)
        let second = first.makeSession()
        _ = try first.load()
        _ = try second.load()
        try first.save([StoredBackupPause(planID: nil, state: .indefinite)])
        #expect(throws: ConfigStoreError.storageChanged) { try second.saveWork([item()]) }
        #expect(throws: ConfigStoreError.notLoaded) { try second.saveWork([]) }
        #expect(try first.load() == [StoredBackupPause(planID: nil, state: .indefinite)])
        #expect(try first.loadWork().isEmpty)
    }

    private func item(planID: UUID = UUID(), date: Date = Date(timeIntervalSince1970: 100)) -> StoredBackupWork {
        StoredBackupWork(
            id: UUID(), planID: planID, repositoryID: UUID(), trigger: .manual, requestedAt: date, state: .pending)
    }
}
