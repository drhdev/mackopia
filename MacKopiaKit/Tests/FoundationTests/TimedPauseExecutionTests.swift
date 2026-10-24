import BackupDomain
import BackupEngine
import Foundation
import Testing

struct TimedPauseExecutionTests {
    @Test func expiryDuringCleanupDefersNewAdmissionUntilCancelledIdentityIsReleased() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let plan = try PreflightTestFixture().plan
        let original = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: time.date)
        let entered = PauseExecutionSignal()
        let cleaning = PauseExecutionSignal()
        let release = PauseExecutionSignal()
        let running = try #require(
            await queue.startNext { job in
                await entered.signal()
                do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                    await cleaning.signal()
                    await release.wait()
                    #expect(await queue.complete(job, wasCancelled: true))
                    throw error
                }
            })
        await entered.wait()
        let pausing = Task { try await queue.pause(until: time.date.addingTimeInterval(60)) }
        await cleaning.wait()
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await queue.pauseState() == nil }
        #expect(await queue.takeNext() == nil)
        await release.signal()
        try await pausing.value
        await #expect(throws: CancellationError.self) { try await running.value }
        let resumed = try #require(await queue.takeNext())
        #expect(resumed.id != original.id)
        #expect(resumed.plan == original.plan)
        #expect(resumed.requestedAt == time.date)
        #expect(await queue.complete(resumed))
        #expect(await queue.takeNext() == nil)
    }

    @Test func stopDuringTimedPauseKeepsDeadlineButDiscardsRestartIntent() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let plan = try PreflightTestFixture().plan
        let original = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: time.date)
        #expect(await queue.takeNext() == original)
        try await queue.pause(planID: plan.id, until: time.date.addingTimeInterval(60))
        #expect(await queue.complete(original, wasCancelled: true))
        await queue.stop(planID: plan.id)
        #expect(await queue.isPaused(plan.id))
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await queue.pauseState(planID: plan.id) == nil }
        #expect(await queue.takeNext() == nil)
        _ = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: time.date)
        #expect(await queue.takeNext() != nil)
    }

    private func wait(_ ready: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !(await ready()) {
            guard clock.now < deadline else { throw PauseExecutionError.timedOut }
            try await clock.sleep(for: .milliseconds(5))
        }
    }
}

private actor PauseExecutionSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private enum PauseExecutionError: Error { case timedOut }
