import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

struct SnapshotVerificationEngineTests {
    @Test func completedCheckSurvivesReopenAndFeedsHealth() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let verifier = VerificationProbe()
        let result = try #require(try await fixture.engine(verifier).verify(planID: fixture.base.plan.id))
        #expect(result.outcome == .succeeded)
        #expect(result.dueAt.timeIntervalSince(result.endedAt) == 7 * 24 * 60 * 60)
        #expect(await verifier.ids == run.sources.map(\.snapshotID))
        #expect(await verifier.percent == 1)
        let reopened = try HistoryStore(directory: fixture.root)
        #expect(
            try await reopened.latestVerification(
                planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                kind: .snapshotVerify, before: fixture.base.time.date) == result)
        let runtime = try fixture.base.runtime(historyOverride: reopened)
        #expect(try await runtime.health(planID: fixture.base.plan.id).severity == .ok)
    }

    @Test func failedCommandRecordsFixedFailureAndLaterSuccessClearsHealth() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let failed = VerificationProbe(mode: .failure)
        await #expect(throws: BackupOperationError.operationFailed) {
            try await fixture.engine(failed).verify(planID: fixture.base.plan.id)
        }
        let runtime = try fixture.base.runtime(historyOverride: fixture.history)
        #expect(try await runtime.health(planID: fixture.base.plan.id).reasons.contains(.verificationFailed))
        fixture.base.time.advance(1)
        let passed = try #require(try await fixture.engine(VerificationProbe()).verify(planID: fixture.base.plan.id))
        #expect(passed.outcome == .succeeded)
        #expect(try await runtime.health(planID: fixture.base.plan.id).severity == .ok)
    }

    @Test func missingIncompleteOrInvalidBackupNeverLaunchesVerification() async throws {
        for mode in ["missing", "partial", "invalid-id"] {
            let fixture = try await VerificationEngineFixture()
            defer { fixture.remove() }
            if mode != "missing" { _ = try await fixture.seedBackup(mode: mode) }
            let verifier = VerificationProbe()
            await #expect(throws: (any Error).self) {
                try await fixture.engine(verifier).verify(planID: fixture.base.plan.id)
            }
            #expect(await verifier.calls == 0)
            #expect(try await fixture.latest() == nil)
        }
    }

    @Test func blockedPreflightAndInvalidOptionsDoNotInventEvidence() async throws {
        let fixture = try await VerificationEngineFixture(sourceAccess: .denied)
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let verifier = VerificationProbe()
        let engine = fixture.engine(verifier)
        #expect(try await engine.verify(planID: fixture.base.plan.id) == nil)
        for percent in [0, 101] {
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await engine.verify(planID: fixture.base.plan.id, filesPercent: percent)
            }
        }
        for duration in [Duration.zero, .seconds(-1), .seconds(32 * 24 * 60 * 60)] {
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await engine.verify(planID: fixture.base.plan.id, validFor: duration)
            }
        }
        #expect(await verifier.calls == 0)
        #expect(try await fixture.latest() == nil)
    }

    @Test func cancellationJoinsCleanupAndPreventsConcurrentRepositoryAccess() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let verifier = VerificationProbe(mode: .wait)
        let engine = fixture.engine(verifier)
        let task = Task { try await engine.verify(planID: fixture.base.plan.id) }
        try await waitForRuntime { await verifier.calls == 1 }
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await engine.verify(planID: fixture.base.plan.id)
        }
        let competing = try await fixture.base.base.preflight.evaluate(
            plan: fixture.base.plan, repository: fixture.base.base.repository)
        #expect(competing.outcome == .blocked)
        task.cancel()
        try await waitForRuntime { await verifier.cleaning }
        let cleanupRace = try await fixture.base.base.preflight.evaluate(
            plan: fixture.base.plan, repository: fixture.base.base.repository)
        #expect(cleanupRace.outcome == .blocked)
        await verifier.releaseCleanup()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await verifier.cleaned)
        #expect(try await fixture.latest() == nil)
        let released = try await fixture.base.base.preflight.evaluate(
            plan: fixture.base.plan, repository: fixture.base.base.repository)
        #expect(released.outcome == .checksPassed)
        #expect(try await engine.verify(planID: fixture.base.plan.id) != nil)
    }

    @Test func configurationChangeDuringCommandDiscardsSuccess() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        _ = try await fixture.seedBackup()
        let verifier = VerificationProbe(mode: .hold)
        let task = Task { try await fixture.engine(verifier).verify(planID: fixture.base.plan.id) }
        try await waitForRuntime { await verifier.calls == 1 }
        try await fixture.base.store.save(BackupConfiguration(repositories: [fixture.base.base.repository], plans: []))
        await verifier.releaseCleanup()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await task.value }
        #expect(try await fixture.latest() == nil)
    }
}

struct VerificationEngineFixture {
    let base: AutomaticRuntimeFixture
    let root: URL
    let history: HistoryStore

    init(sourceAccess: PreflightAccessStatus = .verified) async throws {
        base = try await AutomaticRuntimeFixture(sourceAccess: sourceAccess)
        root = try KopiaProcessTests().temporaryRoot()
        history = try HistoryStore(directory: root)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func engine(
        _ verifier: any SnapshotVerifying, restorer: (any SnapshotTestRestoring)? = nil
    ) -> SnapshotVerificationEngine {
        SnapshotVerificationEngine(
            store: base.store,
            coordinator: BackupOperationCoordinator(preflight: base.base.preflight, protection: ManualTestProtection()),
            verifier: verifier, history: history, restorer: restorer, now: { base.time.date })
    }

    func latest() async throws -> VerificationResult? {
        try await history.latestVerification(
            planID: base.plan.id, repositoryID: base.plan.repositoryID, kind: .snapshotVerify, before: base.time.date)
    }

    func seedBackup(mode: String = "complete") async throws -> JobRun {
        let run = JobRun(
            id: UUID(), planID: base.plan.id, repositoryID: base.plan.repositoryID, trigger: .manual,
            startedAt: base.time.date, endedAt: base.time.date, outcome: .running, sources: [], issues: [])
        try await history.begin(run)
        let sources = base.plan.sources.enumerated().map { index, source in
            JobRun.SourceResult(
                sourceID: source.id,
                snapshotID: mode == "invalid-id" ? "--all-sources" : String(repeating: String(index + 1), count: 32),
                rootID: "k" + String(repeating: "a", count: 32), bytes: 30, files: 1, errors: 0)
        }
        let finished = JobRun(
            id: run.id, planID: run.planID, repositoryID: run.repositoryID, trigger: .manual,
            startedAt: run.startedAt, endedAt: run.endedAt, outcome: .succeeded,
            sources: mode == "partial" ? Array(sources.prefix(1)) : sources, issues: [])
        try await history.finish(finished)
        return finished
    }
}

actor VerificationProbe: SnapshotVerifying {
    enum Mode { case success, failure, wait, hold }
    let mode: Mode
    var calls = 0
    var ids: [String] = []
    var percent = 0
    var cleaning = false
    var cleaned = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(mode: Mode = .success) { self.mode = mode }

    func verify(repository: Repository, snapshotIDs: [String], filesPercent: Int, lowPriority: Bool) async throws {
        calls += 1
        ids = snapshotIDs
        percent = filesPercent
        if mode == .failure { throw NSError(domain: "private-marker", code: 1) }
        if mode == .wait, calls == 1 {
            do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                cleaning = true
                await withCheckedContinuation { continuation = $0 }
                cleaned = true
                throw CancellationError()
            }
        }
        if mode == .hold { await withCheckedContinuation { continuation = $0 } }
    }

    func releaseCleanup() { continuation?.resume(); continuation = nil }
}
