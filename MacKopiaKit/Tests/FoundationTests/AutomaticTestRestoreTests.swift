import BackupDomain
import Foundation
import Persistence
import Testing

@testable import BackupEngine

struct AutomaticTestRestoreTests {
    @Test func automaticBackupRestoresOnceAndReopenedHistorySuppressesUntilDue() async throws {
        let fixture = try await AutomaticRestoreFixture()
        defer { fixture.remove() }
        let probe = TestRestoreProbe()
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { try await fixture.latest() != nil }
        #expect(await probe.calls == 1)
        #expect(await probe.run?.sources.count == 2)
        for service in await fixture.base.sessions.services { #expect(await service.closed) }
        let first = try #require(try await fixture.latest())
        await runtime.shutdown()

        // A new owner reads persisted evidence instead of resetting an in-memory timer.
        let reopened = try HistoryStore(directory: fixture.root)
        let scheduled = fixture.schedule(probe, history: reopened)
        let run = try #require(await probe.run)
        try await scheduled.afterBackup(run)
        #expect(await probe.calls == 1)
        fixture.base.time.advance(first.dueAt.timeIntervalSince(fixture.base.time.date))
        try await scheduled.afterBackup(run)
        #expect(await probe.calls == 2)
        #expect(try await fixture.latest()?.endedAt == first.dueAt)
        #expect(await fixture.base.issues.values.isEmpty)
    }

    @Test func failureIsPersistedReportedAndDoesNotRetryBackup() async throws {
        let fixture = try await AutomaticRestoreFixture()
        defer { fixture.remove() }
        let runtime = try fixture.runtime(TestRestoreProbe(mode: .failure))
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime {
            await fixture.base.issues.values == [.testRestoreFailed(planID: fixture.base.plan.id)]
        }
        #expect(try await fixture.latest()?.outcome == .failed)
        #expect(await fixture.base.sessions.opens == 1)
        await runtime.shutdown()
    }

    @Test(arguments: ["pause", "globalPause", "stop", "shutdown", "reload"])
    func controlsCancelAndJoinRestoreCleanup(_ control: String) async throws {
        let fixture = try await AutomaticRestoreFixture()
        defer { fixture.remove() }
        let probe = TestRestoreProbe(mode: .wait)
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { await probe.calls == 1 }
        let action = Task {
            switch control {
            case "pause": try await runtime.pause(planID: fixture.base.plan.id)
            case "globalPause": try await runtime.pause()
            case "stop": try await runtime.stop(planID: fixture.base.plan.id)
            case "reload": try await runtime.reloadConfiguration()
            default: await runtime.shutdown()
            }
        }
        try await waitForRuntime { await probe.cleaning }
        // Cancellation cannot release the shared repository reservation before cleanup.
        let competing = try await fixture.base.base.preflight.evaluate(
            plan: fixture.base.plan, repository: fixture.base.base.repository)
        #expect(competing.outcome == .blocked)
        #expect(try await fixture.latest() == nil)
        await probe.release()
        try await action.value
        #expect(await fixture.base.issues.values.isEmpty)
        #expect(try await fixture.latest() == nil)
        await runtime.shutdown()
    }

    @Test func pendingBackupWaitsUntilRestoreCompletes() async throws {
        let fixture = try await AutomaticRestoreFixture()
        defer { fixture.remove() }
        let probe = TestRestoreProbe(mode: .hold)
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { await probe.calls == 1 }
        try await runtime.enqueue(planID: fixture.base.plan.id)
        #expect(await fixture.base.sessions.opens == 1)
        await probe.release()
        try await waitForRuntime { await fixture.base.sessions.opens == 2 }
        await runtime.shutdown()
        #expect(await probe.calls == 1)
        #expect(await fixture.base.issues.values.isEmpty)
    }

    @Test func warningAndFailedBackupsCannotTriggerRestore() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let probe = TestRestoreProbe()
        let schedule = AutomaticTestRestore(
            engine: fixture.engine(VerificationProbe(), restorer: probe), history: fixture.history,
            now: { fixture.base.time.date })
        for outcome in [JobRun.Outcome.failed, .cancelled, .succeededWithWarnings] {
            let incomplete = JobRun(
                id: run.id, planID: run.planID, repositoryID: run.repositoryID, trigger: run.trigger,
                startedAt: run.startedAt, endedAt: run.endedAt, outcome: outcome,
                sources: run.sources, issues: [])
            try await schedule.afterBackup(incomplete)
        }
        #expect(await probe.calls == 0)
    }

    @Test func inconclusiveRestoreCreatesNoEvidenceAndRetriesOnNextBackup() async throws {
        let fixture = try await AutomaticRestoreFixture()
        defer { fixture.remove() }
        let probe = TestRestoreProbe(mode: .inconclusive)
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { await probe.calls == 1 }
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { await probe.calls == 2 }
        #expect(try await fixture.latest() == nil)
        #expect(await fixture.base.issues.values.isEmpty)
        await runtime.shutdown()
    }
}

private struct AutomaticRestoreFixture {
    let base: AutomaticRuntimeFixture
    let root: URL
    let history: HistoryStore
    let coordinator: BackupOperationCoordinator

    init() async throws {
        base = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .validIdentifiers)
        root = try KopiaProcessTests().temporaryRoot()
        history = try HistoryStore(directory: root)
        coordinator = BackupOperationCoordinator(preflight: base.base.preflight, protection: ManualTestProtection())
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func schedule(_ probe: TestRestoreProbe, history: HistoryStore? = nil) -> AutomaticTestRestore {
        let history = history ?? self.history
        let engine = SnapshotVerificationEngine(
            store: base.store, coordinator: coordinator, verifier: VerificationProbe(), history: history,
            restorer: probe, now: { base.time.date })
        return AutomaticTestRestore(engine: engine, history: history, now: { base.time.date })
    }
    func runtime(_ probe: TestRestoreProbe) throws -> AutomaticBackupRuntime<SchedulerTestClock> {
        try base.runtime(historyOverride: history, testRestore: schedule(probe), coordinator: coordinator)
    }
    func latest() async throws -> VerificationResult? {
        try await history.latestVerification(
            planID: base.plan.id, repositoryID: base.plan.repositoryID, kind: .testRestore, before: base.time.date)
    }
}
