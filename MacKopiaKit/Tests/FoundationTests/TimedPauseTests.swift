import BackupDomain
import BackupEngine
import Foundation
import Testing

struct TimedPauseTests {
    @Test func oneHourExpiryReleasesHeldQueueAndClearsState() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let plan = try PreflightTestFixture().plan
        let job = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: time.date)
        let deadline = try #require(try BackupPauseOption.oneHour.deadline(after: time.date))
        try await queue.pause(until: deadline)
        try await wait { time.sleeperCount == 1 }
        #expect(await queue.pauseState() == .until(deadline))
        time.advance(3599)
        #expect(await queue.takeNext() == nil)
        time.advance(1)
        try await wait { await queue.pauseState() == nil }
        #expect(await queue.takeNext() == job)
        #expect(time.sleeperCount == 0)
    }

    @Test func overlappingDeadlinesResumeOnlyTheirOwnScope() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let plan = try PreflightTestFixture().plan
        _ = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: time.date)
        try await queue.pause(until: time.date.addingTimeInterval(60))
        try await queue.pause(planID: plan.id, until: time.date.addingTimeInterval(120))
        try await wait { time.sleeperCount == 2 }
        time.advance(60)
        try await wait { await queue.pauseState() == nil }
        #expect(await queue.isPaused(plan.id))
        #expect(await queue.takeNext() == nil)
        time.advance(60)
        try await wait { await queue.pauseState(planID: plan.id) == nil }
        #expect(await queue.takeNext() != nil)
    }

    @Test func replacementAndManualResumeCancelAndJoinOldTimers() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let plan = try PreflightTestFixture().plan
        try await queue.pause(planID: plan.id, until: time.date.addingTimeInterval(10))
        try await wait { time.sleeperCount == 1 }
        await queue.pause(planID: plan.id)
        #expect(time.sleeperCount == 0)
        time.advance(10)
        #expect(await queue.pauseState(planID: plan.id) == .indefinite)
        try await queue.pause(planID: plan.id, until: time.date.addingTimeInterval(20))
        try await wait { time.sleeperCount == 1 }
        try await queue.resume(planID: plan.id, requestedAt: time.date)
        #expect(time.sleeperCount == 0)
        #expect(await queue.pauseState(planID: plan.id) == nil)
    }

    @Test func invalidDeadlineLeavesExistingPauseUntouchedAndPastDeadlineExpires() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        await queue.pause()
        for seconds in [Double.infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            await #expect(throws: DomainValidationError.invalidPlan) {
                try await queue.pause(until: Date(timeIntervalSinceReferenceDate: seconds))
            }
        }
        #expect(await queue.pauseState() == .indefinite)
        try await queue.pause(until: time.date.addingTimeInterval(-1))
        try await wait { await queue.pauseState() == nil }
        #expect(time.sleeperCount == 0)
    }

    @Test func timerFailureAndShutdownKeepPauseVisibleUntilManualResume() async throws {
        struct FailingClock: Clock {
            var now: ContinuousClock.Instant { .now }
            var minimumResolution: Duration { .nanoseconds(1) }
            func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
                throw CancellationError()
            }
        }
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let failed = JobQueue(clock: FailingClock(), now: { date })
        let deadline = date.addingTimeInterval(60)
        try await failed.pause(until: deadline)
        try await wait { await failed.pauseState() == .timerUnavailable(until: deadline) }
        try await failed.resume(requestedAt: date)
        #expect(await failed.pauseState() == nil)
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let until = time.date.addingTimeInterval(60)
        try await queue.pause(until: until)
        try await wait { time.sleeperCount == 1 }
        await queue.cancelPauseTimers()
        #expect(time.sleeperCount == 0)
        #expect(await queue.pauseState() == .timerUnavailable(until: until))
        time.advance(60)
        #expect(await queue.pauseState() != nil)
        try await queue.resume(requestedAt: time.date)
    }

    @Test func backwardClockChangeRearmsWithoutPrematureResumeAndForwardJumpReconciles() async throws {
        let time = SchedulerTestClock()
        let queue = JobQueue(clock: time, now: { time.date })
        let until = time.date.addingTimeInterval(60)
        try await queue.pause(until: until)
        try await wait { time.sleeperCount == 1 }
        time.adjustWallTime(by: -120)
        time.advance(60)
        try await wait { time.sleeperCount == 1 }
        #expect(await queue.pauseState() == .until(until))
        time.advance(119)
        #expect(await queue.pauseState() != nil)
        time.advance(1)
        try await wait { await queue.pauseState() == nil }
        try await queue.pause(until: time.date.addingTimeInterval(60))
        try await wait { time.sleeperCount == 1 }
        time.adjustWallTime(by: 120)
        try await queue.reconcilePauses()
        #expect(await queue.pauseState() == nil)
        #expect(time.sleeperCount == 0)
    }

    @Test(arguments: ["2026-03-28T12:00:00+01:00", "2026-10-24T12:00:00+02:00"])
    func tomorrowMorningUsesLocalCalendarAcrossDSTChanges(start: String) throws {
        let date = try #require(ISO8601DateFormatter().date(from: start))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let tomorrow = try #require(
            try BackupPauseOption.untilTomorrowMorning.deadline(after: date, calendar: calendar))
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: tomorrow)
        #expect(parts.hour == 8)
        #expect(parts.minute == 0)
        #expect(parts.day == (start.contains("03-28") ? 29 : 25))
        #expect(tomorrow.timeIntervalSince(date) == (start.contains("03-28") ? 19 : 21) * 3600)
        #expect(try BackupPauseOption.indefinite.deadline(after: date) == nil)
    }

    private func wait(_ ready: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(5)
        while !(await ready()) {
            guard clock.now < deadline else { throw PauseTestError.timedOut }
            try await clock.sleep(for: .milliseconds(5))
        }
    }
}

private enum PauseTestError: Error { case timedOut }
