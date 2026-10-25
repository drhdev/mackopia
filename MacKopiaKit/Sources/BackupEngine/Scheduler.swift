import BackupDomain
import Foundation

package struct ScheduledRequest: Sendable, Equatable {
    package let planID: UUID
    package let trigger: Trigger
    package let requestedAt: Date
}

/// Time triggers only. The receiver owns fresh configuration admission and the protected engine path.
/// No processes or user-data access are authorized by a scheduler request.
package actor Scheduler {
    private struct Key: Hashable {
        let planID: UUID
        let trigger: Trigger
    }
    private struct Entry {
        let plan: BackupPlan
        var date: Date
        var catchingUp = false
    }

    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let loginReady: Date
    private var calendar: Calendar
    private var entries: [Key: Entry] = [:]
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var receiver: (@Sendable (ScheduledRequest) async -> Void)?

    package init(
        loginDate: Date, calendar: Calendar = .current,
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { .now },
        jitter: @escaping @Sendable () -> Double = { .random(in: -60...60) }
    ) {
        loginReady = loginDate.addingTimeInterval(60)
        self.calendar = calendar
        self.clock = clock
        self.now = now
        self.jitter = jitter
    }

    deinit { timer?.cancel() }

    /// Last runs are supplied by the history owner. Missing history anchors new intervals at startup.
    /// Validate before replacing anything; an invalid configuration cannot partially enable jobs.
    package func replace(plans: [BackupPlan], lastRuns: [UUID: Date] = [:]) throws {
        let date = now()
        guard date.timeIntervalSinceReferenceDate.isFinite, loginReady.timeIntervalSinceReferenceDate.isFinite,
            lastRuns.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }),
            Set(plans.map(\.id)).count == plans.count
        else { throw DomainValidationError.invalidPlan }
        var replacement: [Key: Entry] = [:]
        for plan in plans where plan.isEnabled {
            for trigger in plan.triggers {
                try trigger.validate()
                let key = Key(planID: plan.id, trigger: trigger)
                let next: Date?
                if let existing = entries[key] {
                    next = existing.date
                } else {
                    next = ScheduleCalculation.next(
                        trigger: trigger, after: min(lastRuns[plan.id] ?? date, date),
                        calendar: calendar, jitterSeconds: jitter())
                }
                guard var next else { continue }
                var catchingUp = entries[key]?.catchingUp ?? false
                if next <= date {
                    if plan.conditions.catchUpMissedRuns {
                        next = date.addingTimeInterval(120)
                        catchingUp = true
                    } else {
                        guard
                            let future = ScheduleCalculation.next(
                                trigger: trigger, after: date, calendar: calendar, jitterSeconds: jitter())
                        else { continue }
                        next = future
                    }
                }
                replacement[key] = Entry(plan: plan, date: max(loginReady, next), catchingUp: catchingUp)
            }
        }
        entries = replacement
        armTimer()
    }

    package var nextRunDate: Date? { entries.values.map(\.date).min() }

    package func nextRunDate(planID: UUID) -> Date? {
        entries.filter { $0.key.planID == planID }.values.map(\.date).min()
    }

    /// Wake/clock events replace overdue dates once; repeated notifications do not extend the delay.
    /// Future daily dates are recalculated in the new timezone; interval dates retain their anchor.
    package func reconcile(calendar newCalendar: Calendar? = nil) {
        let date = now()
        if let newCalendar { calendar = newCalendar }
        for (key, var entry) in entries {
            if entry.date <= date {
                if entry.plan.conditions.catchUpMissedRuns {
                    entry.date = max(loginReady, date.addingTimeInterval(120))
                    entry.catchingUp = true
                } else if let future = next(key.trigger, after: date) {
                    entry.date = max(loginReady, future)
                } else {
                    entries.removeValue(forKey: key)
                    continue
                }
            } else if newCalendar != nil, !entry.catchingUp, case .daily = key.trigger,
                let future = next(key.trigger, after: date)
            {
                entry.date = max(loginReady, future)
            }
            entries[key] = entry
        }
        armTimer()
    }

    /// Consume atomically before delivery. Concurrent ticks cannot enqueue a missed run twice.
    /// Several due triggers for one plan produce one request; elapsed intervals never create a burst.
    package func takeDue() -> [ScheduledRequest] {
        let date = now()
        let due = entries.filter { $0.value.date <= date }.sorted {
            if $0.value.date != $1.value.date { return $0.value.date < $1.value.date }
            if $0.key.planID == $1.key.planID {
                return ($0.value.plan.triggers.firstIndex(of: $0.key.trigger) ?? 0)
                    < ($1.value.plan.triggers.firstIndex(of: $1.key.trigger) ?? 0)
            }
            return $0.key.planID.uuidString < $1.key.planID.uuidString
        }
        var delivered: Set<UUID> = []
        var requests: [ScheduledRequest] = []
        for (key, _) in due {
            if delivered.insert(key.planID).inserted {
                requests.append(ScheduledRequest(planID: key.planID, trigger: key.trigger, requestedAt: date))
            }
            if let future = next(key.trigger, after: date) {
                entries[key]?.date = max(loginReady, future)
                entries[key]?.catchingUp = false
            } else {
                entries.removeValue(forKey: key)
            }
        }
        armTimer()
        return requests
    }

    /// Only one cancellable sleep exists. Wake/clock/configuration events invalidate its generation.
    package func start(deliver: @escaping @Sendable (ScheduledRequest) async -> Void) {
        receiver = deliver
        armTimer()
    }

    package func stop() {
        receiver = nil
        timer?.cancel()
        timer = nil
        generation &+= 1
    }

    private func next(_ trigger: Trigger, after date: Date) -> Date? {
        ScheduleCalculation.next(trigger: trigger, after: date, calendar: calendar, jitterSeconds: jitter())
    }

    private func armTimer() {
        timer?.cancel()
        timer = nil
        generation &+= 1
        guard receiver != nil, let deadline = nextRunDate else { return }
        let version = generation
        let delay = Duration.seconds(max(0, deadline.timeIntervalSince(now())))
        let clock = self.clock
        timer = makeTimer(clock: clock, delay: delay, version: version)
    }

    private func makeTimer<C: Clock>(clock: C, delay: Duration, version: UInt64) -> Task<Void, Never>
    where C.Duration == Duration {
        // Capture before creating the task: executor delay must not move a scheduled deadline.
        let instant = clock.now.advanced(by: delay)
        return Task { [weak self] in
            do { try await clock.sleep(until: instant, tolerance: nil) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.fire(version: version)
        }
    }

    private func fire(version: UInt64) async {
        guard generation == version, let receiver else { return }
        timer = nil
        let requests = takeDue()
        for request in requests {
            // stop/replacement may occur while the receiver awaits admission for another plan.
            guard self.receiver != nil,
                entries.keys.contains(where: { $0.planID == request.planID && $0.trigger == request.trigger })
            else { continue }
            await receiver(request)
        }
    }
}
