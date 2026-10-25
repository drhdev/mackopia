import BackupDomain
import Foundation
import Persistence

/// In-memory admission and run controls; callers supply execution, cleanup, and repository gates.
package actor JobQueue {
    /// Single execution owner; coalesced notifications are wakeups, never an execution authority.
    package let admissions: AsyncStream<UInt64>
    private let admissionSignal: AsyncStream<UInt64>.Continuation
    private var pauseRevision: UInt64 = 0
    var pending: [BackupJob] = []
    var recoveryHeld = false
    var workRestored = false
    var discardedWork: Set<UUID> = []
    private var configurationHeld = false
    private var controlHolds: Set<UUID> = []
    var activeJobs: [UUID: BackupJob] = [:]
    private var executions: [UUID: Execution] = [:]
    struct Pause {
        let id: UUID
        var state: BackupPauseState
    }
    var pauses: [UUID?: Pause] = [:]
    private var pauseTimers: [UUID: Task<Void, Never>] = [:]
    private let pauseTimer: BackupPauseTimer
    let now: @Sendable () -> Date
    var pausePersistence: (any BackupPauseStoring)?
    var pausePersistenceFailed = false
    var canRestorePauses: Bool { pending.isEmpty && activeJobs.isEmpty && pauses.isEmpty }
    var interrupted: [UUID: BackupJob] = [:]
    private var resumeRequestedAt: [UUID: Date] = [:]

    private struct Execution: Sendable {
        let cancel: @Sendable () -> Void
        let join: @Sendable () async -> Void
    }

    package init() {
        (admissions, admissionSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        pausePersistence = nil
        pauseTimer = BackupPauseTimer(clock: ContinuousClock())
        now = { .now }
    }

    package init<C: Clock>(
        clock: C, now: @escaping @Sendable () -> Date, pausePersistence: (any BackupPauseStoring)? = nil
    ) where C.Duration == Duration {
        self.pausePersistence = pausePersistence
        (admissions, admissionSignal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        pauseTimer = BackupPauseTimer(clock: clock)
        self.now = now
    }

    /// Duplicates refresh the pending plan snapshot while retaining the first trigger, request date,
    /// ID, and FIFO position. An active snapshot is immutable; new requests retain one follow-up.
    /// Plan enablement, configured triggers, and current preflight conditions are caller policy.
    @discardableResult
    package func enqueue(plan: BackupPlan, trigger: Trigger, requestedAt: Date) throws -> BackupJob {
        try Task.checkCancellation()
        guard !pausePersistenceFailed else { throw ConfigStoreError.storageUnavailable }
        guard !isPaused(plan.id) else { throw JobAdmissionError.planPaused }
        try trigger.validate()
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainValidationError.invalidPlan
        }
        let job = insert(plan: plan, trigger: trigger, requestedAt: requestedAt)
        guard !pausePersistenceFailed else { throw ConfigStoreError.storageUnavailable }
        return job
    }

    private func insert(plan: BackupPlan, trigger: Trigger, requestedAt: Date) -> BackupJob {
        defer { _ = persistWork(); admissionSignal.yield(pauseRevision) }
        if let index = pending.firstIndex(where: { $0.plan.id == plan.id }) {
            let existing = pending[index]
            let refreshed = BackupJob(
                id: existing.id, plan: plan, trigger: existing.trigger, requestedAt: existing.requestedAt)
            pending[index] = refreshed
            return refreshed
        }
        let job = BackupJob(id: UUID(), plan: plan, trigger: trigger, requestedAt: requestedAt)
        pending.append(job)
        return job
    }

    /// FIFO follows admission order, not wall time. Skip active plans so their follow-ups cannot
    /// starve other plans. There is at most one active admission per plan.
    package func takeNext() -> BackupJob? {
        guard !pausePersistenceFailed, !configurationHeld, controlHolds.isEmpty, !recoveryHeld else { return nil }
        guard let index = pending.firstIndex(where: { activeJobs[$0.plan.id] == nil && !isPaused($0.plan.id) }) else {
            return nil
        }
        let job = pending.remove(at: index)
        activeJobs[job.plan.id] = job
        guard persistWork() else { return nil }
        return job
    }

    /// Complete only after execution and cleanup finish. A stale completion cannot release a newer
    /// admission for the same plan; pending follow-ups remain queued on either success or failure.
    @discardableResult
    package func complete(_ job: BackupJob, wasCancelled: Bool = false) -> Bool {
        guard activeJobs[job.plan.id]?.id == job.id else { return false }
        activeJobs.removeValue(forKey: job.plan.id)
        discardedWork.remove(job.id)
        executions.removeValue(forKey: job.id)
        admissionSignal.yield(pauseRevision)
        if !wasCancelled {
            interrupted.removeValue(forKey: job.plan.id)
            resumeRequestedAt.removeValue(forKey: job.plan.id)
        } else if !isPaused(job.plan.id), let date = resumeRequestedAt.removeValue(forKey: job.plan.id),
            let interruptedJob = interrupted.removeValue(forKey: job.plan.id)
        {
            _ = insert(plan: interruptedJob.plan, trigger: interruptedJob.trigger, requestedAt: date)
        }
        _ = persistWork()
        return true
    }

    /// Task creation and cancellation registration share the dequeue turn: pause cannot miss a run
    /// between dequeue and execution. The operation owns cleanup and calls complete afterwards.
    package func startNext<Value: Sendable>(
        operation: @escaping @Sendable (BackupJob) async throws -> Value
    ) -> Task<Value, any Error>? {
        guard let job = takeNext() else { return nil }
        let task = Task {
            try await QueueExecution.$jobID.withValue(job.id) {
                try await operation(job)
            }
        }
        executions[job.id] = Execution(cancel: { task.cancel() }, join: { _ = await task.result })
        return task
    }

    /// nil means global. Existing pending requests are held; new triggers are rejected. Cancellation
    /// reaches the normal source-cancel/history/cleanup path, and external callers await its end.
    package func pause(planID: UUID? = nil) async {
        let old = replacePause(planID: planID, state: .indefinite)
        await cancelAndJoin(pausedJobs(planID: planID))
        await joinTimer(old)
    }

    /// Wall deadline is explicit; monotonic waiting includes system sleep. Expired deadlines resume
    /// immediately, but the existing active identity still blocks restart until cleanup completes.
    package func pause(planID: UUID? = nil, until: Date) async throws {
        try validatePauseDate(until)
        let old = replacePause(planID: planID, state: .until(until))
        armPauseTimer(planID: planID, until: until)
        await cancelAndJoin(pausedJobs(planID: planID))
        await joinTimer(old)
    }

    package func pauseState(planID: UUID? = nil) -> BackupPauseState? { pauses[planID]?.state }

    /// Removes only this pause scope. A still-effective global or individual pause keeps work held.
    /// Interrupted work gets a fresh run ID after cleanup, coalescing any previously queued follow-up.
    package func resume(planID: UUID? = nil, requestedAt: Date) async throws {
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else { throw DomainValidationError.invalidPlan }
        try savePauses(storedPauses().filter { $0.planID != planID })
        let old = pauses.removeValue(forKey: planID)?.id
        if old != nil { pauseRevision &+= 1 }
        if let old { pauseTimers[old]?.cancel() }
        let ready = interrupted.values.filter { !isPaused($0.plan.id) }.sorted {
            if $0.requestedAt == $1.requestedAt { return $0.plan.id.uuidString < $1.plan.id.uuidString }
            return $0.requestedAt < $1.requestedAt
        }
        for job in ready {
            if activeJobs[job.plan.id] != nil {
                resumeRequestedAt[job.plan.id] = requestedAt
            } else {
                _ = insert(plan: job.plan, trigger: job.trigger, requestedAt: requestedAt)
                interrupted.removeValue(forKey: job.plan.id)
                resumeRequestedAt.removeValue(forKey: job.plan.id)
            }
        }
        admissionSignal.yield(pauseRevision)
        await joinTimer(old)
    }

    /// Stop drops follow-ups and any pause-resume intent; the next ordinary trigger remains valid.
    /// An existing explicit pause is preserved.
    package func stop(planID: UUID) async {
        pending.removeAll { $0.plan.id == planID }
        interrupted.removeValue(forKey: planID)
        resumeRequestedAt.removeValue(forKey: planID)
        let jobs = activeJobs.values.filter { $0.plan.id == planID }
        discardedWork.formUnion(jobs.map(\.id))
        _ = persistWork()
        await cancelAndJoin(jobs)
    }

    /// Reload holds dequeue without changing durable pauses or cancelling unaffected active work.
    func beginControl(_ id: UUID) { controlHolds.insert(id) }
    func endControl(_ id: UUID) {
        controlHolds.remove(id)
        admissionSignal.yield(pauseRevision)
    }

    func holdForConfiguration(_ held: Bool) {
        configurationHeld = held
        if !held { admissionSignal.yield(pauseRevision) }
    }

    package func isPaused(_ planID: UUID) -> Bool { pauses[nil] != nil || pauses[planID] != nil }

    /// The monitoring owner calls this on wake/wall-clock changes. A timezone change does not alter
    /// an already chosen absolute date. Timer failure keeps the pause visible and fails closed.
    package func reconcilePauses() async throws {
        try validatePauseDate(now())
        let entries = pauses
        for (planID, entry) in entries {
            guard pauses[planID]?.id == entry.id, case .until(let until) = entry.state else { continue }
            if until <= now() {
                try await resume(planID: planID, requestedAt: now())
            } else {
                let old = replacePause(planID: planID, state: .until(until))
                armPauseTimer(planID: planID, until: until)
                await joinTimer(old)
            }
        }
    }

    /// Ends timer ownership without silently lifting a pause; explicit resume remains available.
    package func cancelPauseTimers() async {
        for (scope, entry) in pauses {
            if case .until(let until) = entry.state {
                pauses[scope] = Pause(id: UUID(), state: .timerUnavailable(until: until))
            }
        }
        let timers = pauseTimers
        for timer in timers.values { timer.cancel() }
        for id in timers.keys { await joinTimer(id) }
    }

    func replacePause(planID: UUID?, state: BackupPauseState) -> UUID? {
        let old = pauses.updateValue(Pause(id: UUID(), state: state), forKey: planID)?.id
        if let old { pauseTimers[old]?.cancel() }
        return old
    }

    private func pausedJobs(planID: UUID?) -> [BackupJob] {
        let jobs = activeJobs.values.filter { planID == nil || $0.plan.id == planID }
        for job in jobs { interrupted[job.plan.id] = job }
        return jobs
    }

    func armPauseTimer(planID: UUID?, until: Date) {
        guard let id = pauses[planID]?.id else { return }
        let date = now()
        let remaining = until.timeIntervalSince(date)
        guard date.timeIntervalSinceReferenceDate.isFinite, remaining.isFinite,
            abs(remaining) <= Date.distantFuture.timeIntervalSince(.distantPast)
        else {
            markTimerUnavailable(planID: planID, until: until)
            return
        }
        let delay = max(0, remaining)
        pauseTimers[id] = pauseTimer.start(id, .seconds(delay)) { ready in
            await self.pauseTimerFired(planID: planID, id: id, ready: ready)
        }
    }

    private func pauseTimerFired(planID: UUID?, id: UUID, ready: Bool) async {
        defer { pauseTimers.removeValue(forKey: id) }
        guard let pause = pauses[planID], pause.id == id, case .until(let until) = pause.state else { return }
        let date = now()
        guard ready, date.timeIntervalSinceReferenceDate.isFinite else {
            markTimerUnavailable(planID: planID, until: until)
            return
        }
        if until > date {
            _ = replacePause(planID: planID, state: .until(until))
            armPauseTimer(planID: planID, until: until)
        } else {
            // date was validated above, so resume cannot reject it.
            do { try await resume(planID: planID, requestedAt: date) } catch {
                if pauses[planID]?.id == id { markTimerUnavailable(planID: planID, until: until) }
            }
        }
    }

    func signalPausePersistenceFailure() { admissionSignal.yield(pauseRevision) }

    private func validatePauseDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite, now().timeIntervalSinceReferenceDate.isFinite,
            date <= .distantFuture, date >= .distantPast,
            date.timeIntervalSince(now()).isFinite
        else { throw DomainValidationError.invalidPlan }
    }

    private func joinTimer(_ id: UUID?) async {
        guard let id, let timer = pauseTimers[id], PauseTimerWorker.id != id else { return }
        await timer.value
        pauseTimers.removeValue(forKey: id)
    }

    private func cancelAndJoin(_ jobs: [BackupJob]) async {
        let running = jobs.compactMap { job in executions[job.id].map { (job.id, $0) } }
        for (_, execution) in running { execution.cancel() }
        for (id, execution) in running where id != QueueExecution.jobID { await execution.join() }
    }
}

private enum QueueExecution {
    @TaskLocal static var jobID: UUID?
}
