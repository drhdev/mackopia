import BackupDomain
import Foundation
import Testing

@testable import BackupEngine
@testable import Persistence

struct PersistentPauseTests {
    @Test func timedPlanPauseSurvivesRestartWithoutInventingGlobalPauseOrReplayingWork() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let runtime = try fixture.runtime()
        try await runtime.start()
        let deadline = fixture.time.date.addingTimeInterval(120)
        try await runtime.pause(planID: fixture.plan.id, until: deadline)
        await runtime.shutdown()
        #expect(
            try fixture.store.pauseStore.load() == [StoredBackupPause(planID: fixture.plan.id, state: .until(deadline))]
        )
        fixture.time.advance(60)
        let monitor = RuntimeMonitor()
        let restarted = try fixture.runtime(monitorOverride: monitor)
        try await restarted.start()
        #expect(await restarted.pauseState() == nil)
        #expect(await restarted.pauseState(planID: fixture.plan.id) == .until(deadline))
        await #expect(throws: JobAdmissionError.planPaused) { try await restarted.enqueue(planID: fixture.plan.id) }
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(60)
        try await waitForRuntime { await restarted.pauseState(planID: fixture.plan.id) == nil }
        #expect(try fixture.store.pauseStore.load().isEmpty)
        #expect(await fixture.history.started.isEmpty)
        try await restarted.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        await restarted.shutdown()
    }

    @Test func restoredGlobalAndPlanPausesMustBeResumedSeparately() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.pause()
        try await runtime.pause(planID: fixture.plan.id)
        await runtime.shutdown()
        let restarted = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await restarted.start()
        #expect(await restarted.pauseState() == .indefinite)
        #expect(await restarted.pauseState(planID: fixture.plan.id) == .indefinite)
        try await restarted.resume()
        await #expect(throws: JobAdmissionError.planPaused) { try await restarted.enqueue(planID: fixture.plan.id) }
        #expect(try fixture.store.pauseStore.load() == [StoredBackupPause(planID: fixture.plan.id, state: .indefinite)])
        try await restarted.stop(planID: fixture.plan.id)
        #expect(await restarted.pauseState(planID: fixture.plan.id) == .indefinite)
        try await restarted.resume(planID: fixture.plan.id)
        #expect(try fixture.store.pauseStore.load().isEmpty)
        await restarted.shutdown()
    }

    @Test func failedDurablePauseStopsActiveExecutionAndReportsFixedIssue() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        fixture.files.state.withLock { $0.failingWrite = .pauses }
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await runtime.pause() }
        try await waitForRuntime { await runtime.state == .controlStateUnavailable }
        try await waitForRuntime { await fixture.issues.values == [.controlStateUnavailable] }
        #expect(await service.closed)
        #expect(await service.cancellations == 1)
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        await #expect(throws: CancellationError.self) { try await runtime.enqueue(planID: fixture.plan.id) }
    }

    @Test func failedResumeNeverReleasesPauseOrStartsQueuedWork() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.pause(planID: fixture.plan.id)
        fixture.files.state.withLock { $0.failingWrite = .pauses }
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await runtime.resume(planID: fixture.plan.id) }
        try await waitForRuntime { await runtime.state == .controlStateUnavailable }
        #expect(await runtime.pauseState(planID: fixture.plan.id) == .indefinite)
        #expect(await fixture.sessions.opens == 0)
        #expect(try fixture.store.pauseStore.load() == [StoredBackupPause(planID: fixture.plan.id, state: .indefinite)])
    }

    @Test func corruptStatePreventsMonitoringAndExpiredOrDeletedScopesArePruned() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        fixture.files.state.withLock { $0.pauses = Data("invalid".utf8) }
        let runtime = try fixture.runtime()
        await #expect(throws: ConfigStoreError.invalidConfiguration) { try await runtime.start() }
        #expect(await fixture.monitor.observing == false)
        #expect(await fixture.sessions.opens == 0)
        #expect(fixture.time.sleeperCount == 0)
        fixture.files.state.withLock { $0.pauses = nil }
        _ = try fixture.store.pauseStore.load()
        try fixture.store.pauseStore.save([
            StoredBackupPause(planID: UUID(), state: .indefinite),
            StoredBackupPause(planID: fixture.plan.id, state: .until(fixture.time.date)),
        ])
        let restarted = try fixture.runtime(monitorOverride: RuntimeMonitor())
        try await restarted.start()
        #expect(await restarted.pauseState(planID: fixture.plan.id) == nil)
        #expect(try fixture.store.pauseStore.load().isEmpty)
        await restarted.shutdown()
    }

    @Test func timerFailureIsDurableAndRemainsPausedAfterDeadlineAndRestart() async throws {
        struct FailingClock: Clock {
            var now: ContinuousClock.Instant { .now }
            var minimumResolution: Duration { .nanoseconds(1) }
            func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
                throw CancellationError()
            }
        }
        let fixture = try PreflightTestFixture()
        let files = MemoryConfigFiles()
        let store = BackupPauseStore(files: files)
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let deadline = date.addingTimeInterval(60)
        let first = JobQueue(clock: FailingClock(), now: { date }, pausePersistence: store)
        try await first.restorePauses(planIDs: [fixture.plan.id])
        try await first.pausePersistently(planID: fixture.plan.id, until: deadline)
        try await waitForRuntime {
            await first.pauseState(planID: fixture.plan.id) == .timerUnavailable(until: deadline)
        }
        let time = SchedulerTestClock(date: deadline.addingTimeInterval(60))
        let second = JobQueue(clock: time, now: { time.date }, pausePersistence: BackupPauseStore(files: files))
        try await second.restorePauses(planIDs: [fixture.plan.id])
        #expect(await second.pauseState(planID: fixture.plan.id) == .timerUnavailable(until: deadline))
        #expect(time.sleeperCount == 0)
        try await second.resume(planID: fixture.plan.id, requestedAt: time.date)
        #expect(await second.pauseState(planID: fixture.plan.id) == nil)
    }

    @Test func automaticExpiryWriteFailureClosesAdmissionAndKeepsHeldWork() async throws {
        let fixture = try PreflightTestFixture()
        let files = MemoryConfigFiles()
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date }, pausePersistence: BackupPauseStore(files: files))
        try await queue.restorePauses(planIDs: [fixture.plan.id])
        _ = try await queue.enqueue(plan: fixture.plan, trigger: .manual, requestedAt: time.date)
        let deadline = time.date.addingTimeInterval(60)
        try await queue.pausePersistently(planID: fixture.plan.id, until: deadline)
        files.state.withLock { $0.failingWrite = .pauses }
        try await waitForRuntime { time.sleeperCount == 1 }
        time.advance(60)
        try await waitForRuntime { await queue.pausePersistenceFailed }
        #expect(await queue.takeNext() == nil)
        #expect(await queue.isPaused(fixture.plan.id))
        await queue.cancelPauseTimers()
    }
}
