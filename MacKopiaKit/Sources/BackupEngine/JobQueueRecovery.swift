import BackupDomain
import Foundation
import Persistence

extension JobQueue {
    func recoveryWork() throws -> [StoredBackupWork] {
        try (pausePersistence as? any BackupWorkStoring)?.loadWork() ?? []
    }

    /// Rebuild requests from current configuration, never old paths or stale event evidence.
    /// A new admission ID separates abandoned history from the fresh protected attempt.
    func restoreWork(
        _ work: [StoredBackupWork], configuration: BackupConfiguration, completed: Set<UUID>
    ) throws -> Bool {
        guard pending.isEmpty, activeJobs.isEmpty, !workRestored else { throw ConfigStoreError.storageChanged }
        var seen: Set<UUID> = []
        for item in work where !completed.contains(item.id) {
            guard let plan = configuration.plans.first(where: { $0.id == item.planID }), plan.isEnabled,
                plan.repositoryID == item.repositoryID,
                item.trigger == .manual || plan.triggers.contains(item.trigger),
                seen.insert(plan.id).inserted
            else { continue }
            pending.append(BackupJob(id: UUID(), plan: plan, trigger: item.trigger, requestedAt: item.requestedAt))
        }
        workRestored = true
        recoveryHeld = !pending.isEmpty
        guard persistWork() else { throw ConfigStoreError.storageUnavailable }
        return recoveryHeld
    }

    func releaseRecovery() {
        recoveryHeld = false
        signalPausePersistenceFailure()
    }

    /// Mutate and commit in one actor turn; a write error closes dequeue before any wakeup.
    @discardableResult
    func persistWork() -> Bool {
        guard !pausePersistenceFailed else { return false }
        guard workRestored, let store = pausePersistence as? any BackupWorkStoring else { return true }
        func stored(_ job: BackupJob, _ state: StoredBackupWork.State) -> StoredBackupWork {
            StoredBackupWork(
                id: job.id, planID: job.plan.id, repositoryID: job.plan.repositoryID,
                trigger: job.trigger, requestedAt: job.requestedAt, state: state)
        }
        let active = activeJobs.values.filter { !discardedWork.contains($0.id) }
        let paused = interrupted.values.filter { activeJobs[$0.plan.id] == nil }
        let work =
            pending.map { stored($0, .pending) }
            + active.sorted { $0.id.uuidString < $1.id.uuidString }.map { stored($0, .active) }
            + paused.sorted { $0.id.uuidString < $1.id.uuidString }.map { stored($0, .interrupted) }
        do { try store.saveWork(work); return true } catch {
            pausePersistenceFailed = true
            signalPausePersistenceFailure()
            return false
        }
    }
}
