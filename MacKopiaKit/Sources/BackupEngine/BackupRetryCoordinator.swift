import BackupDomain
import Foundation

/// Only explicit, sanitized transient evidence authorizes retry. Unknown failures fail closed.
package enum BackupRetryReason: Sendable {
    case networkUnavailable, timedOut, destinationTemporarilyUnavailable, permanent

    package static func classify(_ error: any Error) -> Self {
        error as? BackupOperationError == .volumeDisappeared ? .destinationTemporarilyUnavailable : .permanent
    }
}

/// Call only after history finalization, process reaping and queue release. The owner must reset a
/// chain on success, a new ordinary request, pause, stop, or configuration change. No durable restart.
package actor BackupRetryCoordinator<C: Clock> where C.Duration == Duration {
    package typealias Admission = @Sendable (BackupPlan, Repository, Trigger, Date) async throws -> Void
    private struct Chain {
        let id = UUID()
        var attempts = 0
        var isTerminal = false
        var delivering = false
        var failedJobIDs: Set<UUID> = []
        var workerID: UUID?
    }
    private let clock: C
    private let now: @Sendable () -> Date
    private let admit: Admission
    private let terminal: @Sendable (BackupJob) async -> Void
    private var chains: [UUID: Chain] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    package init(
        clock: C, now: @escaping @Sendable () -> Date = { .now },
        admit: @escaping Admission, terminal: @escaping @Sendable (BackupJob) async -> Void
    ) {
        self.clock = clock
        self.now = now
        self.admit = admit
        self.terminal = terminal
    }

    package init(
        clock: C, now: @escaping @Sendable () -> Date = { .now }, runner: ConfiguredJobRunner,
        terminal: @escaping @Sendable (BackupJob) async -> Void
    ) {
        self.clock = clock
        self.now = now
        self.admit = { plan, repository, trigger, date in
            _ = try await runner.enqueue(plan: plan, repository: repository, trigger: trigger, requestedAt: date)
        }
        self.terminal = terminal
    }

    /// Explicit reasons must come from trusted adapters, never raw diagnostic text matching.
    /// Cancellation is suppressed even if a caller incorrectly labels it transient.
    package func failed(
        job: BackupJob, repository: Repository, error: any Error, reason: BackupRetryReason? = nil
    ) async {
        guard !stopped, !Task.isCancelled, !(error is CancellationError) else { return }
        var chain = chains[job.plan.id] ?? Chain()
        guard !chain.isTerminal, !chain.failedJobIDs.contains(job.id) else { return }
        if chain.delivering, let id = chain.workerID, let worker = workers[id], RetryWorker.id != id {
            let chainID = chain.id
            await worker.value
            guard chains[job.plan.id]?.id == chainID else { return }
            await failed(job: job, repository: repository, error: error, reason: reason)
            return
        }
        guard chain.workerID == nil else { return }
        chain.failedJobIDs.insert(job.id)
        guard job.plan.isEnabled, job.plan.repositoryID == repository.id,
            (reason ?? .classify(error)) != .permanent, chain.attempts < 3
        else {
            chain.isTerminal = true
            chains[job.plan.id] = chain
            await terminal(job)
            return
        }
        let delays: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
        let deadline = clock.now.advanced(by: delays[chain.attempts])
        chain.attempts += 1
        let id = UUID()
        chain.workerID = id
        chains[job.plan.id] = chain
        workers[id] = Task {
            await RetryWorker.$id.withValue(id) {
                do {
                    try await self.clock.sleep(until: deadline, tolerance: nil)
                    try Task.checkCancellation()
                    try await self.deliver(job: job, repository: repository, id: id)
                } catch is CancellationError {
                } catch {
                    await self.rejected(job: job, id: id)
                }
                self.finished(planID: job.plan.id, id: id)
            }
        }
    }

    /// Cancels and joins in-flight admission too; exact-config admission checks cancellation again.
    package func reset(planID: UUID) async {
        let id = chains.removeValue(forKey: planID)?.workerID
        guard let id, let task = workers[id] else { return }
        task.cancel()
        if RetryWorker.id != id { await task.value }
    }

    package func resetAll() async {
        chains.removeAll()
        let tasks = workers
        for task in tasks.values { task.cancel() }
        for (id, task) in tasks where id != RetryWorker.id { await task.value }
    }

    /// Terminal lifecycle operation. Create a new coordinator for a new monitoring session.
    package func stop() async {
        stopped = true
        chains.removeAll()
        let tasks = workers
        for task in tasks.values { task.cancel() }
        for (id, task) in tasks where id != RetryWorker.id { await task.value }
    }

    private func deliver(job: BackupJob, repository: Repository, id: UUID) async throws {
        guard !stopped, chains[job.plan.id]?.workerID == id else { return }
        try Task.checkCancellation()
        chains[job.plan.id]?.delivering = true
        try await admit(job.plan, repository, job.trigger, now())
    }

    private func rejected(job: BackupJob, id: UUID) async {
        guard !stopped, chains[job.plan.id]?.workerID == id else { return }
        chains[job.plan.id]?.isTerminal = true
        await terminal(job)
    }

    private func finished(planID: UUID, id: UUID) {
        workers.removeValue(forKey: id)
        if chains[planID]?.workerID == id {
            chains[planID]?.workerID = nil
            chains[planID]?.delivering = false
        }
    }

    var isIdle: Bool { workers.isEmpty }
}

enum RetryWorker {
    @TaskLocal static var id: UUID?
}
