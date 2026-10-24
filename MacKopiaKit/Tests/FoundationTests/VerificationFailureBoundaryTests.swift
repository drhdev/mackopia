import BackupDomain
import BackupEngine
import Foundation
import Persistence
import SystemIntegration
import Testing

struct VerificationFailureBoundaryTests {
    @Test func completionTimePrecedesDelayedProtectionCleanup() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let date = fixture.base.time.date
        let engine = SnapshotVerificationEngine(
            store: fixture.base.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.base.preflight,
                protection: AdvancingVerificationProtection(time: fixture.base.time)),
            verifier: VerificationProbe(), history: fixture.history, now: { fixture.base.time.date })
        let result = try #require(try await engine.verify(planID: fixture.base.plan.id))
        #expect(result.endedAt == date)
        #expect(fixture.base.time.date == date.addingTimeInterval(10))
    }

    @Test func persistenceFailureCannotBeReturnedAsVerificationSuccess() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let verifier = VerificationProbe()
        let engine = SnapshotVerificationEngine(
            store: fixture.base.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.base.preflight, protection: ManualTestProtection()),
            verifier: verifier, history: UnwritableVerificationHistory(base: fixture.history))
        await #expect(throws: ConfigStoreError.storageUnavailable) {
            try await engine.verify(planID: fixture.base.plan.id)
        }
        #expect(await verifier.calls == 1)
        #expect(try await fixture.latest() == nil)
    }

    @Test func sleepFailureDoesNotStartCommandOrRecordAnAttempt() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let verifier = VerificationProbe()
        let engine = SnapshotVerificationEngine(
            store: fixture.base.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.base.preflight, protection: ManualTestProtection()),
            verifier: verifier, history: fixture.history, sleep: UnavailableVerificationSleep())
        await #expect(throws: BackupOperationError.operationFailed) {
            try await engine.verify(planID: fixture.base.plan.id)
        }
        #expect(await verifier.calls == 0)
        #expect(try await fixture.latest() == nil)
    }

    @Test func configEditWhileHistoryIsSuspendedPreventsProcessStart() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let history = SuspendedVerificationHistory(base: fixture.history)
        let verifier = VerificationProbe()
        let engine = SnapshotVerificationEngine(
            store: fixture.base.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.base.preflight, protection: ManualTestProtection()),
            verifier: verifier, history: history)
        let task = Task { try await engine.verify(planID: fixture.base.plan.id) }
        try await waitForRuntime { await history.reading }
        try await fixture.base.store.save(BackupConfiguration(repositories: [fixture.base.base.repository], plans: []))
        await history.release()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await task.value }
        #expect(await verifier.calls == 0)
        #expect(try await fixture.latest() == nil)
    }
}

private struct AdvancingVerificationProtection: BackupOperationProtecting {
    let time: SchedulerTestClock
    func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        let result = try await operation()
        time.advance(10)
        return result
    }
}

private struct UnwritableVerificationHistory: JobHistoryHealthReading, VerificationHistoryRecording {
    let base: HistoryStore
    func healthHistory(planID: UUID, repositoryID: UUID, before: Date) async throws -> JobHealthHistory {
        try await base.healthHistory(planID: planID, repositoryID: repositoryID, before: before)
    }
    func recordVerification(_ result: VerificationResult) throws { throw ConfigStoreError.storageUnavailable }
}

private struct UnavailableVerificationSleep: SleepPreventing {
    func acquire() throws -> any SleepAssertionHolding { throw SleepAssertionError.unavailable }
}

private actor SuspendedVerificationHistory: JobHistoryHealthReading, VerificationHistoryRecording {
    let base: HistoryStore
    var reading = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(base: HistoryStore) { self.base = base }
    func healthHistory(planID: UUID, repositoryID: UUID, before: Date) async throws -> JobHealthHistory {
        reading = true
        await withCheckedContinuation { continuation = $0 }
        return try await base.healthHistory(planID: planID, repositoryID: repositoryID, before: before)
    }
    func recordVerification(_ result: VerificationResult) async throws { try await base.recordVerification(result) }
    func release() { continuation?.resume(); continuation = nil }
}
