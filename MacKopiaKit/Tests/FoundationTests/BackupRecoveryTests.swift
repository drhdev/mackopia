import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import BackupEngine
@testable import Persistence

struct BackupRecoveryTests {
    @Test func abandonedRunBecomesInterruptedAndOneFreshAttemptUsesNormalEngine() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let work = item(fixture, state: .active)
        try await history.begin(run(work, outcome: .running, at: fixture.time.date))
        try seed(fixture, work: [work, item(fixture, state: .pending)])
        let runtime = try fixture.runtime(historyOverride: history)
        try await runtime.start()
        let old = try #require(try await history.recent().first)
        #expect(old.id == work.id)
        #expect(old.outcome == .cancelled)
        #expect(old.issues == [.processInterrupted])
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(119)
        #expect(await fixture.sessions.opens == 0)
        fixture.time.advance(1)
        try await waitForRuntime {
            let opens = await fixture.sessions.opens
            return (try? await history.recent().count) == 2 && opens == 1
        }
        try await waitForRuntime { (try? await history.recent().first?.outcome) == .succeeded }
        #expect(try await history.recent().first?.id != work.id)
        // History commits before queue completion; observe the queue's durable completion boundary.
        try await waitForRuntime { await runtime.queue.activeJobs.isEmpty }
        let reopened = fixture.store.pauseStore.makeSession()
        _ = try reopened.load()
        #expect(try reopened.loadWork().isEmpty)
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func restoredWorkHonorsOverlappingPausesAndStopSurvivesRestart() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        try seed(
            fixture, work: [item(fixture, state: .interrupted)],
            pauses: [
                StoredBackupPause(planID: nil, state: .indefinite),
                StoredBackupPause(planID: fixture.plan.id, state: .indefinite),
            ])
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(120)
        try await runtime.resume()
        #expect(await fixture.history.started.isEmpty)
        try await runtime.stop(planID: fixture.plan.id)
        await runtime.shutdown()
        let next = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await next.start()
        try await next.resume(planID: fixture.plan.id)
        #expect(fixture.time.sleeperCount == 0)
        #expect(await fixture.history.started.isEmpty)
        await next.shutdown()
    }

    @Test func resumeAfterRestartReleasesInterruptedWorkThroughFreshPreflight() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], sourceAccess: .unknown)
        try seed(
            fixture, work: [item(fixture, state: .active)],
            pauses: [
                StoredBackupPause(planID: fixture.plan.id, state: .indefinite)
            ])
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(120)
        try await runtime.resume(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        #expect(await fixture.history.finished.first?.outcome == .skipped)
        #expect(await fixture.sessions.opens == 0)
        await runtime.shutdown()
    }

    @Test func completedIntentAndChangedDestinationOrRemovedTriggerAreNotReplayed() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let work = item(fixture, state: .active)
        try await history.begin(run(work, outcome: .running, at: fixture.time.date))
        try await history.finish(run(work, outcome: .succeeded, at: fixture.time.date))
        try seed(fixture, work: [work])
        let runtime = try fixture.runtime(historyOverride: history)
        try await runtime.start()
        #expect(fixture.time.sleeperCount == 0)
        #expect(await fixture.sessions.opens == 0)
        await runtime.shutdown()
        try seed(fixture, work: [item(fixture, state: .pending, repositoryID: UUID())])
        let changed = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await changed.start()
        #expect(fixture.time.sleeperCount == 0)
        await changed.shutdown()
        try seed(fixture, work: [item(fixture, state: .pending, trigger: .onVolumeMount)])
        let removed = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await removed.start()
        #expect(fixture.time.sleeperCount == 0)
        #expect(await fixture.history.started.isEmpty)
        await removed.shutdown()
    }

    @Test func enqueueAndStopWriteFailuresCloseAdmissionAndPreserveLastDurableIntent() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        try seed(fixture, work: [item(fixture, state: .pending)])
        let runtime = try fixture.runtime()
        try await runtime.start()
        fixture.files.state.withLock { $0.failingWrite = .pauses }
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await runtime.stop(planID: fixture.plan.id) }
        try await waitForRuntime { await runtime.state == .controlStateUnavailable }
        #expect(await fixture.sessions.opens == 0)
        fixture.files.state.withLock { $0.failingWrite = nil }
        let saved = fixture.store.pauseStore.makeSession()
        _ = try saved.load()
        #expect(try saved.loadWork().count == 1)
        let fresh = try await AutomaticRuntimeFixture(triggers: [.manual])
        let other = try fresh.runtime()
        try await other.start()
        fresh.files.state.withLock { $0.failingWrite = .pauses }
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await other.enqueue(planID: fresh.plan.id) }
        try await waitForRuntime { await other.state == .controlStateUnavailable }
        #expect(await fresh.sessions.opens == 0)
    }

    @Test func shutdownPreservesQueuedIntentWithoutPersistingGlobalPause() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        try seed(fixture, work: [item(fixture, state: .pending)])
        let runtime = try fixture.runtime()
        try await runtime.start()
        await runtime.shutdown()
        let saved = fixture.store.pauseStore.makeSession()
        #expect(try saved.load().isEmpty)
        #expect(try saved.loadWork().count == 1)
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func activePausePersistsInterruptedIntentAndRestartResumeCompletesIt() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        try await runtime.pause(planID: fixture.plan.id)
        let saved = fixture.store.pauseStore.makeSession()
        _ = try saved.load()
        #expect(try saved.loadWork().first?.state == .interrupted)
        #expect(await service.closed)
        await runtime.shutdown()
        let restarted = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await restarted.start()
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(120)
        try await restarted.resume(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 2 }
        #expect(await fixture.history.finished.last?.outcome == .succeeded)
        #expect(await fixture.sessions.opens == 2)
        _ = try saved.load()
        #expect(try saved.loadWork().isEmpty)
        await restarted.shutdown()
    }

    private func seed(
        _ fixture: AutomaticRuntimeFixture, work: [StoredBackupWork], pauses: [StoredBackupPause] = []
    ) throws {
        let store = fixture.store.pauseStore.makeSession()
        _ = try store.load()
        try store.save(pauses)
        try store.saveWork(work)
    }

    private func item(
        _ fixture: AutomaticRuntimeFixture, state: StoredBackupWork.State,
        repositoryID: UUID? = nil, trigger: Trigger = .manual
    ) -> StoredBackupWork {
        StoredBackupWork(
            id: UUID(), planID: fixture.plan.id, repositoryID: repositoryID ?? fixture.plan.repositoryID,
            trigger: trigger, requestedAt: fixture.time.date, state: state)
    }

    private func run(_ work: StoredBackupWork, outcome: JobRun.Outcome, at date: Date) -> JobRun {
        JobRun(
            id: work.id, planID: work.planID, repositoryID: work.repositoryID, trigger: work.trigger,
            startedAt: date, endedAt: date, outcome: outcome, sources: [], issues: [])
    }
}
