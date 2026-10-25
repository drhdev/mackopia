import BackupDomain
import Foundation
import Persistence
import Testing

@testable import BackupEngine

struct AutomaticSnapshotVerificationTests {
    @Test func automaticBackupVerifiesOnceAndReopenedHistorySuppressesUntilDue() async throws {
        let fixture = try await AutomaticVerifyFixture()
        defer { fixture.remove() }
        let probe = VerificationProbe()
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { try await fixture.latest() != nil }
        #expect(await probe.calls == 1)
        #expect(await probe.percent == 10)
        #expect(try await fixture.latest()?.filesPercent == 10)
        for service in await fixture.base.sessions.services { #expect(await service.closed) }
        let first = try #require(try await fixture.latest())
        #expect(first.dueAt.timeIntervalSince(first.endedAt) == 7 * 24 * 60 * 60)
        await runtime.shutdown()

        // A new owner reads persisted evidence instead of resetting an in-memory timer.
        let reopened = try HistoryStore(directory: fixture.root)
        let scheduled = fixture.schedule(probe, history: reopened)
        let run = try #require(
            try await fixture.history.healthHistory(
                planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                before: fixture.base.time.date
            ).latestSuccess)
        try await scheduled.afterBackup(run)
        #expect(await probe.calls == 1)
        fixture.base.time.advance(first.dueAt.timeIntervalSince(fixture.base.time.date))
        try await scheduled.afterBackup(run)
        #expect(await probe.calls == 2)
        #expect(await probe.percent == 1)
        #expect(try await fixture.latest()?.endedAt == first.dueAt)
        #expect(await fixture.base.issues.values.isEmpty)
    }

    @Test func failureIsPersistedReportedAndDoesNotRetryBackup() async throws {
        let fixture = try await AutomaticVerifyFixture()
        defer { fixture.remove() }
        let runtime = try fixture.runtime(VerificationProbe(mode: .failure))
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime {
            await fixture.base.issues.values == [.verificationFailed(planID: fixture.base.plan.id)]
        }
        #expect(try await fixture.latest()?.outcome == .failed)
        #expect(await fixture.base.sessions.opens == 1)
        await runtime.shutdown()
    }

    @Test(arguments: ["pause", "globalPause", "stop", "shutdown", "reload"])
    func controlsCancelAndJoinVerifyCleanup(_ control: String) async throws {
        let fixture = try await AutomaticVerifyFixture()
        defer { fixture.remove() }
        let probe = VerificationProbe(mode: .wait)
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
        await probe.releaseCleanup()
        try await action.value
        #expect(await fixture.base.issues.values.isEmpty)
        #expect(try await fixture.latest() == nil)
        await runtime.shutdown()
    }

    @Test func pendingBackupWaitsUntilVerifyCompletes() async throws {
        let fixture = try await AutomaticVerifyFixture()
        defer { fixture.remove() }
        let probe = VerificationProbe(mode: .hold)
        let runtime = try fixture.runtime(probe)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime { await probe.calls == 1 }
        try await runtime.enqueue(planID: fixture.base.plan.id)
        #expect(await fixture.base.sessions.opens == 1)
        await probe.releaseCleanup()
        try await waitForRuntime { await fixture.base.sessions.opens == 2 }
        await runtime.shutdown()
        #expect(await probe.calls == 1)
        #expect(await fixture.base.issues.values.isEmpty)
    }

    @Test func failedVerifyStillAllowsIndependentRestoreEvidence() async throws {
        let fixture = try await AutomaticVerifyFixture()
        defer { fixture.remove() }
        let restore = TestRestoreProbe()
        let restoreEngine = SnapshotVerificationEngine(
            store: fixture.base.store, coordinator: fixture.coordinator, verifier: VerificationProbe(),
            history: fixture.history, restorer: restore, now: { fixture.base.time.date })
        let runtime = try fixture.base.runtime(
            historyOverride: fixture.history, verification: fixture.schedule(VerificationProbe(mode: .failure)),
            testRestore: AutomaticTestRestore(
                engine: restoreEngine, history: fixture.history, now: { fixture.base.time.date }),
            coordinator: fixture.coordinator)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.base.plan.id)
        try await waitForRuntime {
            try await fixture.history.latestVerification(
                planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID,
                kind: .testRestore, before: fixture.base.time.date) != nil
        }
        #expect(try await fixture.latest()?.outcome == .failed)
        #expect(await restore.calls == 1)
        #expect(await fixture.base.issues.values == [.verificationFailed(planID: fixture.base.plan.id)])
        let health = try await fixture.history.healthHistory(
            planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID, before: fixture.base.time.date)
        #expect(health.latestVerification?.outcome == .failed)
        await runtime.shutdown()
    }

    @Test func restoreAndForeignEvidenceDoNotPostponeVerify() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        for (planID, repositoryID, kind) in [
            (run.planID, run.repositoryID, VerificationResult.Kind.testRestore),
            (UUID(), run.repositoryID, .snapshotVerify),
            (run.planID, UUID(), .snapshotVerify),
        ] {
            try await fixture.history.recordVerification(
                VerificationResult(
                    planID: planID, repositoryID: repositoryID, kind: kind,
                    startedAt: fixture.base.time.date, endedAt: fixture.base.time.date,
                    dueAt: fixture.base.time.date.addingTimeInterval(30 * 24 * 60 * 60), outcome: .succeeded))
        }
        let probe = VerificationProbe()
        try await AutomaticSnapshotVerification(
            engine: fixture.engine(probe), history: fixture.history,
            now: { fixture.base.time.date }
        ).afterBackup(run)
        #expect(await probe.calls == 1)
        #expect(try await fixture.latest()?.outcome == .succeeded)
    }

    @Test func warningAndFailedBackupsCannotTriggerVerify() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let probe = VerificationProbe()
        let schedule = AutomaticSnapshotVerification(
            engine: fixture.engine(probe), history: fixture.history,
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

}

private struct AutomaticVerifyFixture {
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
    func schedule(_ probe: VerificationProbe, history: HistoryStore? = nil) -> AutomaticSnapshotVerification {
        let history = history ?? self.history
        let engine = SnapshotVerificationEngine(
            store: base.store, coordinator: coordinator, verifier: probe, history: history, now: { base.time.date })
        return AutomaticSnapshotVerification(engine: engine, history: history, now: { base.time.date })
    }
    func runtime(_ probe: VerificationProbe) throws -> AutomaticBackupRuntime<SchedulerTestClock> {
        try base.runtime(historyOverride: history, verification: schedule(probe), coordinator: coordinator)
    }
    func latest() async throws -> VerificationResult? {
        try await history.latestVerification(
            planID: base.plan.id, repositoryID: base.plan.repositoryID, kind: .snapshotVerify, before: base.time.date)
    }
}
