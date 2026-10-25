import BackupDomain
import BackupEngine
import Foundation
import SystemIntegration
import Testing

struct SchedulerTests {
    @Test func delayedTimerTaskRetainsTheOriginalMonotonicDeadline() async throws {
        let time = SchedulerTestClock()
        let scheduler = scheduler(time)
        try await scheduler.replace(plans: [plan(triggers: [.interval(minutes: 2)])])
        let delivered = SchedulerDeliveries()
        // Both calls run on the scheduler actor without suspension; its timer task cannot start yet.
        await scheduler.startThenAdvance(time) { await delivered.append($0) }
        do {
            try await waitForRuntime { time.sleeperCount == 1 }
            time.advance(1)
            try await waitForRuntime(timeout: .seconds(1)) { await delivered.count == 1 }
            await scheduler.stop()
        } catch {
            await scheduler.stop()
            throw error
        }
    }

    @Test func simulatedSystemEventsReconcileSchedulerAndForwardStateHints() async throws {
        let time = SchedulerTestClock()
        let scheduler = scheduler(time)
        try await scheduler.replace(plans: [plan(triggers: [.interval(minutes: 5)])])
        time.advance(3600)
        let forwarded = SchedulerSystemEventProbe()
        let events: [SystemEvent] = [.woke, .clockChanged, .timeZoneChanged, .volumeMounted(uuid: UUID().uuidString)]
        try await scheduler.observeSystemEvents(
            using: ReplayedSystemEvents(events: events),
            changed: { event in
                await forwarded.record(event)
            })
        #expect(await forwarded.events == events)
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(120))
        #expect(await scheduler.takeDue().isEmpty)
        time.advance(120)
        #expect(await scheduler.takeDue().count == 1)
    }

    @Test func intervalWaitsAfterLoginAndCoalescesElapsedOccurrences() async throws {
        let time = SchedulerTestClock()
        let plan = try plan(triggers: [.interval(minutes: 1), .interval(minutes: 2), .manual])
        let scheduler = scheduler(time)
        try await scheduler.replace(plans: [plan])
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(60))
        time.advance(59)
        #expect(await scheduler.takeDue().isEmpty)
        time.advance(541)
        let due = await scheduler.takeDue()
        #expect(due.count == 1)
        #expect(due.first?.planID == plan.id)
        #expect(await scheduler.takeDue().isEmpty)
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(60))
    }

    @Test func startupAndWakeCatchUpOnceAfterTwoMinutes() async throws {
        let time = SchedulerTestClock()
        let plan = try plan(triggers: [.interval(minutes: 5)])
        let scheduler = scheduler(time)
        try await scheduler.replace(plans: [plan], lastRuns: [plan.id: time.date.addingTimeInterval(-3600)])
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(120))
        time.advance(30)
        await scheduler.reconcile()
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(90))
        time.advance(90)
        #expect(await scheduler.takeDue().count == 1)
        time.advance(3600)
        await scheduler.reconcile()
        #expect(await scheduler.takeDue().isEmpty)
        time.advance(120)
        #expect(await scheduler.takeDue().count == 1)
        #expect(await scheduler.takeDue().isEmpty)
    }

    @Test func optOutSkipsMissedRunsAndDisabledOrManualPlansNeverSchedule() async throws {
        let time = SchedulerTestClock()
        let optedOut = try plan(triggers: [.interval(minutes: 5)], catchUp: false)
        let disabled = try plan(triggers: [.interval(minutes: 1)], enabled: false)
        let manual = try plan(triggers: [.manual, .onVolumeMount, .onNetworkReachable])
        let scheduler = scheduler(time)
        try await scheduler.replace(
            plans: [optedOut, disabled, manual], lastRuns: [optedOut.id: time.date.addingTimeInterval(-3600)])
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(300))
        #expect(await scheduler.nextRunDate(planID: disabled.id) == nil)
        #expect(await scheduler.nextRunDate(planID: manual.id) == nil)
        time.advance(3600)
        await scheduler.reconcile()
        #expect(await scheduler.takeDue().isEmpty)
        #expect(await scheduler.nextRunDate == time.date.addingTimeInterval(300))
    }

    @Test func replacementRemovesOldTriggersAndRejectsInvalidStateAtomically() async throws {
        let time = SchedulerTestClock()
        let original = try plan(triggers: [.interval(minutes: 5)])
        let scheduler = scheduler(time)
        try await scheduler.replace(plans: [original])
        let next = await scheduler.nextRunDate
        await #expect(throws: DomainValidationError.invalidPlan) {
            try await scheduler.replace(plans: [original, original])
        }
        #expect(await scheduler.nextRunDate == next)
        try await scheduler.replace(plans: [plan(id: original.id, triggers: [.manual])])
        #expect(await scheduler.nextRunDate == nil)
        time.advance(3600)
        #expect(await scheduler.takeDue().isEmpty)
    }

    @Test func weeklyDatesRespectWeekdaysTimezoneAndDST() async throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        let daily = Trigger.daily(hour: 2, minute: 30, weekdays: [.sunday])
        let spring = try date("2026-03-28T12:00:00Z")
        #expect(
            ScheduleCalculation.next(trigger: daily, after: spring, calendar: berlin, jitterSeconds: 60)
                == (try date("2026-03-29T01:00:00Z")))
        let autumn = try date("2026-10-24T12:00:00Z")
        let first = try #require(
            ScheduleCalculation.next(trigger: daily, after: autumn, calendar: berlin, jitterSeconds: 0))
        #expect(first == (try date("2026-10-25T00:30:00Z")))
        #expect(
            ScheduleCalculation.next(trigger: daily, after: first, calendar: berlin, jitterSeconds: 0)
                == (try date("2026-11-01T01:30:00Z")))
        let time = SchedulerTestClock(date: autumn)
        let scheduler = scheduler(time)
        let plan = try plan(triggers: [daily])
        try await scheduler.replace(plans: [plan])
        #expect(await scheduler.nextRunDate == (try date("2026-10-25T02:30:00Z")))
        await scheduler.reconcile(calendar: berlin)
        #expect(await scheduler.nextRunDate == first)
    }

    @Test func jitterIsBoundedAndExtremeIntervalsDoNotOverflow() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let calendar = Calendar(identifier: .gregorian)
        for (jitter, expected): (Double, Double) in [(-100, 1), (100, 120), (.nan, 60)] {
            #expect(
                ScheduleCalculation.next(
                    trigger: .interval(minutes: 1), after: start, calendar: calendar, jitterSeconds: jitter)
                    == start.addingTimeInterval(expected))
        }
        #expect(
            ScheduleCalculation.next(
                trigger: .interval(minutes: Int.max / 60), after: start, calendar: calendar, jitterSeconds: 0) == nil)
    }

    @Test func injectedClockDrivesTimerAndStopCancelsPendingSleep() async throws {
        let time = SchedulerTestClock()
        let scheduler = scheduler(time)
        let plan = try plan(triggers: [.interval(minutes: 1)])
        try await scheduler.replace(plans: [plan])
        let queue = JobQueue()
        let delivered = SchedulerDeliveries()
        await scheduler.start { request in
            #expect(!Task.isCancelled)
            do {
                try await queue.enqueue(plan: plan, trigger: request.trigger, requestedAt: request.requestedAt)
            } catch {
                Issue.record(error)
            }
            await delivered.append(request)
        }
        try await wait { time.sleeperCount == 1 }
        time.advance(60)
        try await wait { await delivered.count == 1 }
        let job = try #require(await queue.takeNext())
        #expect(job.plan.id == plan.id)
        #expect(job.trigger == .interval(minutes: 1))
        #expect(await queue.complete(job))
        try await wait { time.sleeperCount == 1 }
        await scheduler.stop()
        try await wait { time.sleeperCount == 0 }
        time.advance(3600)
        #expect(await delivered.count == 1)
    }

    @Test func timezoneEventPreservesPendingDailyCatchUp() async throws {
        let time = SchedulerTestClock(date: try date("2026-10-24T12:00:00Z"))
        let scheduler = scheduler(time)
        let plan = try plan(triggers: [.daily(hour: 8, minute: 0, weekdays: Set(Weekday.allCases))])
        try await scheduler.replace(plans: [plan], lastRuns: [plan.id: time.date.addingTimeInterval(-86400)])
        let catchUpDate = await scheduler.nextRunDate
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = try #require(TimeZone(identifier: "Europe/Berlin"))
        await scheduler.reconcile(calendar: berlin)
        #expect(await scheduler.nextRunDate == catchUpDate)
        time.advance(120)
        #expect(await scheduler.takeDue().count == 1)
        #expect(await scheduler.nextRunDate == (try date("2026-10-25T07:00:00Z")))
    }

    private func scheduler(_ time: SchedulerTestClock) -> Scheduler {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return Scheduler(loginDate: time.date, calendar: calendar, clock: time, now: { time.date }, jitter: { 0 })
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        try #require(await condition())
    }

    private func plan(
        id: UUID = UUID(), triggers: [Trigger], enabled: Bool = true, catchUp: Bool = true
    ) throws -> BackupPlan {
        try BackupPlan(
            id: id, name: "Test", isEnabled: enabled, repositoryID: UUID(),
            sources: [
                BackupSource(
                    path: "/Source",
                    volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
            ],
            triggers: triggers,
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: true,
                catchUpMissedRuns: catchUp),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: true, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }
}

private struct ReplayedSystemEvents: SystemEventMonitoring {
    let events: [SystemEvent]
    func observe(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws {
        for event in events {
            try Task.checkCancellation()
            await deliver(event)
        }
    }
}

private actor SchedulerDeliveries {
    private(set) var count = 0
    func append(_ request: ScheduledRequest) { count += 1 }
}

private actor SchedulerSystemEventProbe {
    private(set) var events: [SystemEvent] = []
    func record(_ event: SystemEvent) { events.append(event) }
}

private extension Scheduler {
    func startThenAdvance(_ clock: SchedulerTestClock, deliver: @escaping @Sendable (ScheduledRequest) async -> Void) {
        start(deliver: deliver)
        clock.advance(119)
    }
}
