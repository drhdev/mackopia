import BackupDomain
import Foundation
import Persistence
import Testing

struct HistoryStoreTests {
    @Test func durableRunsTransitionOnceAndKeepInterruptedRowsVisible() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        let store = try HistoryStore(directory: directory)
        let run = run(outcome: .running)
        try await store.begin(run)
        let finished = self.run(id: run.id, outcome: .succeeded)
        try await store.finish(finished)
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await store.finish(finished) }
        let interrupted = self.run(outcome: .running)
        try await store.begin(interrupted)
        let reopened = try HistoryStore(directory: directory)
        #expect(Set(try await reopened.recent()) == Set([finished, interrupted]))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("history.sqlite").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        await #expect(throws: ConfigStoreError.invalidConfiguration) { try await store.recent(limit: 0) }
    }

    @Test func rejectsSymlinkedDatabaseWithoutModifyingTarget() throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target")
        let marker = Data("private-marker".utf8)
        try marker.write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("history.sqlite"), withDestinationURL: target)
        #expect(throws: ConfigStoreError.storageUnavailable) { try HistoryStore(directory: root) }
        #expect(try Data(contentsOf: target) == marker)
    }

    private func run(id: UUID = UUID(), outcome: JobRun.Outcome) -> JobRun {
        JobRun(
            id: id, planID: UUID(), repositoryID: UUID(), trigger: .manual, startedAt: .now, endedAt: .now,
            outcome: outcome, sources: [], issues: [])
    }
}
