import BackupDomain
import Foundation

/// In-memory admission bookkeeping only; callers own execution, cancellation, and repository gates.
package actor JobQueue {
    private var pending: [BackupJob] = []
    private var activeJobIDs: [UUID: UUID] = [:]

    package init() {}

    /// Duplicates refresh the pending plan snapshot while retaining the first trigger, request date,
    /// ID, and FIFO position. An active snapshot is immutable; new requests retain one follow-up.
    /// Plan enablement, configured triggers, and current preflight conditions are caller policy.
    @discardableResult
    package func enqueue(plan: BackupPlan, trigger: Trigger, requestedAt: Date) throws -> BackupJob {
        try trigger.validate()
        guard requestedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DomainValidationError.invalidPlan
        }
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
        guard let index = pending.firstIndex(where: { activeJobIDs[$0.plan.id] == nil }) else { return nil }
        let job = pending.remove(at: index)
        activeJobIDs[job.plan.id] = job.id
        return job
    }

    /// Complete only after execution and cleanup finish. A stale completion cannot release a newer
    /// admission for the same plan; pending follow-ups remain queued on either success or failure.
    @discardableResult
    package func complete(_ job: BackupJob) -> Bool {
        guard activeJobIDs[job.plan.id] == job.id else { return false }
        activeJobIDs.removeValue(forKey: job.plan.id)
        return true
    }
}
