import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

struct TestRestoreEngineTests {
    @Test func successAndFailureAreDurableAndSeparateFromVerify() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let backup = try await fixture.seedBackup()
        let verifier = VerificationProbe()
        let probe = TestRestoreProbe()
        let engine = fixture.engine(verifier, restorer: probe)
        let result = try #require(try await engine.testRestore(planID: fixture.base.plan.id))
        #expect(result.kind == .testRestore && result.outcome == .succeeded)
        #expect(result.dueAt.timeIntervalSince(result.endedAt) == 30 * 24 * 60 * 60)
        #expect(await probe.run == backup)
        #expect(await verifier.calls == 0)
        let reopened = try HistoryStore(directory: fixture.root)
        #expect(
            try await reopened.latestVerification(
                planID: result.planID, repositoryID: result.repositoryID,
                kind: .testRestore, before: fixture.base.time.date) == result)
        #expect(try await fixture.latest() == nil)
        fixture.base.time.advance(1)
        let failure = fixture.engine(verifier, restorer: TestRestoreProbe(mode: .failure))
        await #expect(throws: BackupOperationError.operationFailed) {
            try await failure.testRestore(planID: fixture.base.plan.id)
        }
        #expect(
            try await reopened.latestVerification(
                planID: result.planID, repositoryID: result.repositoryID,
                kind: .testRestore, before: fixture.base.time.date)?.outcome == .failed)
    }

    @Test func inconclusiveMissingBackupAndBlockedPreflightCreateNoEvidence() async throws {
        for mode in ["inconclusive", "missing", "partial", "blocked"] {
            let fixture = try await VerificationEngineFixture(sourceAccess: mode == "blocked" ? .denied : .verified)
            defer { fixture.remove() }
            if mode != "missing" { _ = try await fixture.seedBackup(mode: mode == "partial" ? "partial" : "complete") }
            let probe = TestRestoreProbe(mode: .inconclusive)
            let engine = fixture.engine(VerificationProbe(), restorer: probe)
            if mode == "missing" || mode == "partial" {
                await #expect(throws: BackupOperationError.snapshotMissing) {
                    try await engine.testRestore(planID: fixture.base.plan.id)
                }
            } else {
                #expect(try await engine.testRestore(planID: fixture.base.plan.id) == nil)
            }
            #expect(await probe.calls == (mode == "inconclusive" ? 1 : 0))
            #expect(
                try await fixture.history.latestVerification(
                    planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                    kind: .testRestore, before: fixture.base.time.date) == nil)
        }
    }

    @Test func cancellationKeepsReservationUntilRestoreCleanupAndCreatesNoEvidence() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let probe = TestRestoreProbe(mode: .wait)
        let engine = fixture.engine(VerificationProbe(), restorer: probe)
        let task = Task { try await engine.testRestore(planID: fixture.base.plan.id) }
        try await waitForRuntime { await probe.calls == 1 }
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await engine.verify(planID: fixture.base.plan.id)
        }
        task.cancel()
        try await waitForRuntime { await probe.cleaning }
        #expect(
            try await fixture.base.base.preflight.evaluate(
                plan: fixture.base.plan, repository: fixture.base.base.repository
            ).outcome == .blocked)
        await probe.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(
            try await fixture.history.latestVerification(
                planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                kind: .testRestore, before: fixture.base.time.date) == nil)
    }

    @Test func changedConfigurationDiscardsRestoreSuccess() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let probe = TestRestoreProbe(mode: .hold)
        let engine = fixture.engine(VerificationProbe(), restorer: probe)
        let task = Task { try await engine.testRestore(planID: fixture.base.plan.id) }
        try await waitForRuntime { await probe.calls == 1 }
        try await fixture.base.store.save(BackupConfiguration(repositories: [fixture.base.base.repository], plans: []))
        await probe.release()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await task.value }
        #expect(
            try await fixture.history.latestVerification(
                planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                kind: .testRestore, before: fixture.base.time.date) == nil)
    }
}

actor TestRestoreProbe: SnapshotTestRestoring {
    enum Mode { case success, failure, inconclusive, wait, hold }
    let mode: Mode
    var calls = 0
    var run: JobRun?
    var cleaning = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode = .success) { self.mode = mode }
    func testRestore(
        repository: Repository, sources: [BackupSource], run: JobRun, lowPriority: Bool
    ) async throws -> Bool {
        calls += 1
        self.run = run
        if mode == .failure { throw NSError(domain: "private-marker", code: 1) }
        if mode == .wait {
            do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                cleaning = true
                await withCheckedContinuation { continuation = $0 }
                throw CancellationError()
            }
        }
        if mode == .hold { await withCheckedContinuation { continuation = $0 } }
        return mode != .inconclusive
    }
    func release() { continuation?.resume(); continuation = nil }
}
