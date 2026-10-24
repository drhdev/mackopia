import BackupDomain
import Foundation
import Testing

@testable import BackupEngine
@testable import Persistence

struct BackupRetryCoordinatorTests {
    @Test func threeRetriesUseMonotonicDelaysThenReportTerminalFailure() async throws {
        let fixture = try PreflightTestFixture()
        let time = SchedulerTestClock()
        let probe = RetryProbe()
        let retry = BackupRetryCoordinator(
            clock: time, now: { time.date }, admit: { _, _, _, date in await probe.admit(date) },
            terminal: { _ in await probe.fail() })
        for seconds in [60.0, 300, 900] {
            let job = makeJob(fixture, date: time.date)
            let before = await probe.dates.count
            await retry.failed(job: job, repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
            await retry.failed(job: job, repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
            try await wait { time.sleeperCount == 1 }
            time.advance(seconds - 1)
            #expect(await probe.dates.count == before)
            time.advance(1)
            try await wait { await retry.isIdle }
            #expect(await probe.dates.count == before + 1)
            #expect(await probe.dates.last == time.date)
        }
        await retry.failed(
            job: makeJob(fixture, date: time.date), repository: fixture.repository,
            error: BackupOperationError.volumeDisappeared)
        #expect(await probe.failures == 1)
        #expect(time.sleeperCount == 0)
        await retry.stop()
    }

    @Test func unknownPermanentAndCancellationNeverCreateRetryTimers() async throws {
        let fixture = try PreflightTestFixture()
        let time = SchedulerTestClock()
        let probe = RetryProbe()
        let retry = BackupRetryCoordinator(
            clock: time, admit: { _, _, _, _ in Issue.record("Unexpected retry") },
            terminal: { _ in await probe.fail() })
        for error in [BackupOperationError.operationFailed, .snapshotIncomplete, .identitiesChanged] {
            await retry.reset(planID: fixture.plan.id)
            await retry.failed(job: makeJob(fixture), repository: fixture.repository, error: error)
        }
        await retry.reset(planID: fixture.plan.id)
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupPreflightError.backupPasswordRequired)
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: CancellationError(), reason: .timedOut)
        #expect(await probe.failures == 4)
        #expect(time.sleeperCount == 0)
        #expect(await retry.isIdle)
    }

    @Test func resetCancelsTimerAndStartsNewChainAtOneMinute() async throws {
        let fixture = try PreflightTestFixture()
        let time = SchedulerTestClock()
        let probe = RetryProbe()
        let retry = BackupRetryCoordinator(
            clock: time, admit: { _, _, _, date in await probe.admit(date) },
            terminal: { _ in Issue.record("Unexpected terminal failure") })
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupOperationError.operationFailed,
            reason: .networkUnavailable)
        try await wait { time.sleeperCount == 1 }
        await retry.reset(planID: fixture.plan.id)
        #expect(time.sleeperCount == 0)
        #expect(await retry.isIdle)
        time.advance(900)
        #expect(await probe.dates.isEmpty)
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupOperationError.operationFailed,
            reason: .timedOut)
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await retry.isIdle }
        #expect(await probe.dates.count == 1)
        await retry.stop()
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
        #expect(await retry.isIdle)
        #expect(time.sleeperCount == 0)
    }

    @Test func changedConfigurationRejectsRetryAtActualQueueBoundary() async throws {
        let fixture = try PreflightTestFixture()
        let store = ConfigStore(files: MemoryConfigFiles(), codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [fixture.plan]))
        let queue = JobQueue()
        let runner = ConfiguredJobRunner(
            store: store, queue: queue, coordinator: BackupOperationCoordinator(preflight: fixture.preflight))
        let time = SchedulerTestClock()
        let probe = RetryProbe()
        let retry = BackupRetryCoordinator(clock: time, runner: runner, terminal: { _ in await probe.fail() })
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
        try await wait { time.sleeperCount == 1 }
        try await store.save(BackupConfiguration(repositories: [], plans: []))
        time.advance(60)
        try await wait { await retry.isIdle }
        #expect(await probe.failures == 1)
        #expect(await queue.takeNext() == nil)
        #expect(await fixture.probe.operations.isEmpty)
    }

    @Test func retryCreatesFreshAdmissionWithoutStartingProcesses() async throws {
        let fixture = try PreflightTestFixture()
        let store = ConfigStore(files: MemoryConfigFiles(), codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [fixture.plan]))
        let queue = JobQueue()
        let runner = ConfiguredJobRunner(
            store: store, queue: queue, coordinator: BackupOperationCoordinator(preflight: fixture.preflight))
        let time = SchedulerTestClock()
        let retry = BackupRetryCoordinator(
            clock: time, now: { time.date }, runner: runner,
            terminal: { _ in Issue.record("Unexpected terminal failure") })
        let original = makeJob(fixture, date: time.date)
        await retry.failed(job: original, repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await retry.isIdle }
        let admitted = try #require(await queue.takeNext())
        #expect(admitted.id != original.id)
        #expect(admitted.plan == original.plan)
        #expect(admitted.trigger == original.trigger)
        #expect(admitted.requestedAt == time.date)
        #expect(await queue.complete(admitted))
        #expect(await fixture.probe.operations.isEmpty)
        await retry.reset(planID: fixture.plan.id)
        await retry.stop()
    }

    @Test func stopJoinsAdmissionCancellation() async throws {
        let fixture = try PreflightTestFixture()
        let time = SchedulerTestClock()
        let probe = RetryProbe()
        let retry = BackupRetryCoordinator(
            clock: time,
            admit: { _, _, _, _ in
                await probe.admit(time.date)
                do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                    await probe.fail()
                    throw error
                }
            }, terminal: { _ in Issue.record("Cancellation must not notify") })
        await retry.failed(
            job: makeJob(fixture), repository: fixture.repository, error: BackupOperationError.volumeDisappeared)
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await probe.dates.count == 1 }
        await retry.stop()
        #expect(await probe.failures == 1)
        #expect(await retry.isIdle)
    }

    private func makeJob(_ fixture: PreflightTestFixture, date: Date = .now) -> BackupJob {
        BackupJob(id: UUID(), plan: fixture.plan, trigger: .manual, requestedAt: date)
    }

    private func wait(_ ready: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !(await ready()) {
            guard clock.now < deadline else { throw RetryTestError.timedOut }
            try await clock.sleep(for: .milliseconds(5))
        }
    }
}

private actor RetryProbe {
    var dates: [Date] = []
    var failures = 0
    func admit(_ date: Date) { dates.append(date) }
    func fail() { failures += 1 }
}

private enum RetryTestError: Error { case timedOut }
