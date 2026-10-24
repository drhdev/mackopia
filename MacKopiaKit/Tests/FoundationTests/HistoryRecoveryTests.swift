import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import Persistence

struct HistoryRecoveryTests {
    @Test func reconciliationIsIdempotentPreservesSuccessAndNeverInventsWork() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let abandoned = run(plan: fixture.plan, at: fixture.time.date.addingTimeInterval(100))
        try await history.begin(abandoned)
        let completed = run(plan: fixture.plan, at: fixture.time.date.addingTimeInterval(-10))
        try await history.begin(completed)
        let success = JobRun(
            id: completed.id, planID: completed.planID, repositoryID: completed.repositoryID, trigger: .manual,
            startedAt: completed.startedAt, endedAt: completed.endedAt, outcome: .succeeded, sources: [], issues: [])
        try await history.finish(success)
        let expected: Set<UUID> = [success.id]
        #expect(
            try await history.reconcileInterrupted(at: fixture.time.date, workIDs: [abandoned.id, success.id])
                == expected)
        let once = try await history.recent()
        let interrupted = try #require(once.first { $0.id == abandoned.id })
        #expect(interrupted.outcome == .cancelled)
        #expect(interrupted.endedAt == abandoned.startedAt)
        #expect(interrupted.issues == [.processInterrupted])
        #expect(once.contains(success))
        #expect(
            try await history.reconcileInterrupted(at: fixture.time.date, workIDs: [abandoned.id, success.id])
                == expected)
        #expect(try await history.recent() == once)
        let runtime = try fixture.runtime(historyOverride: history)
        try await runtime.start()
        #expect(fixture.time.sleeperCount == 0)
        #expect(await fixture.sessions.opens == 0)
        await runtime.shutdown()
    }

    @Test func corruptAbandonedPayloadRollsBackEveryReconciliationUpdate() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let first = run(plan: fixture.plan, at: fixture.time.date)
        try await history.begin(first)
        let database = await history.database
        try await database.write { db in
            try db.execute(
                sql: "INSERT INTO runs (id, planID, startedAt, outcome, payload) VALUES (?, ?, ?, ?, ?)",
                arguments: ["invalid-after-uuid", fixture.plan.id.uuidString, 0, "running", Data("invalid".utf8)])
        }
        await #expect(throws: ConfigStoreError.storageUnavailable) {
            try await history.reconcileInterrupted(at: fixture.time.date, workIDs: [])
        }
        // Remove the deliberately corrupt fixture before using the public decoded-history reader.
        try await database.write { db in
            try db.execute(sql: "DELETE FROM runs WHERE id = ?", arguments: ["invalid-after-uuid"])
        }
        #expect(try await history.recent() == [first])
    }

    @Test func failedReconciliationPreventsStartupAndShutdownCannotBeUndoneByLateReply() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let history = ControlledRecoveryHistory()
        let runtime = try fixture.runtime(historyOverride: history)
        let starting = Task { try await runtime.start() }
        try await waitForRuntime { await history.reading }
        await runtime.shutdown()
        await history.release()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(await runtime.state == .stopped)
        #expect(await fixture.monitor.observing == false)
        let failing = try fixture.runtime(historyOverride: ControlledRecoveryHistory(failing: true))
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await failing.start() }
        #expect(await failing.state == .stopped)
        #expect(await fixture.sessions.opens == 0)
    }

    private func run(plan: BackupPlan, at date: Date) -> JobRun {
        JobRun(
            id: UUID(), planID: plan.id, repositoryID: plan.repositoryID, trigger: .manual,
            startedAt: date, endedAt: date, outcome: .running, sources: [], issues: [])
    }
}

private actor ControlledRecoveryHistory: JobHistoryRecording, JobHistoryRecovering {
    let failing: Bool
    var reading = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(failing: Bool = false) { self.failing = failing }
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func reconcileInterrupted(at date: Date, workIDs: Set<UUID>) async throws -> Set<UUID> {
        if failing { throw ConfigStoreError.storageUnavailable }
        reading = true
        await withCheckedContinuation { continuation = $0 }
        return []
    }
    func release() { continuation?.resume(); continuation = nil }
}
