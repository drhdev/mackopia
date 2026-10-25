import BackupDomain
import Foundation

extension AutomaticBackupRuntime {
    /// Explicit checks share the single drain owner with backups and their post-processing.
    func requestCheck(_ planID: UUID) async throws {
        guard state == .running, controls.isEmpty, check != nil,
            configuration?.plans.contains(where: { $0.id == planID && $0.isEnabled }) == true
        else {
            throw LocalServiceIssue.invalidRequest
        }
        guard !(await queue.isPaused(planID)) else { throw LocalServiceIssue.planPaused }
        guard state == .running, controls.isEmpty,
            configuration?.plans.contains(where: { $0.id == planID && $0.isEnabled }) == true
        else {
            throw LocalServiceIssue.busy
        }
        if !requestedChecks.contains(planID) { requestedChecks.append(planID) }
        await queueChanged(observedPauseRevision)
    }

    func performRequestedCheck() async -> Bool {
        guard controls.isEmpty, let id = requestedChecks.first, let check else { return false }
        checkingPlanID = id
        defer { checkingPlanID = nil }
        requestedChecks.removeFirst()
        guard !(await queue.isPaused(id)), !blockedPlans.contains(id), !blockingAll, state == .running else {
            return true
        }
        let task = Task { try await check(id) }
        postBackupTask = (id, task)
        await activity(id)
        let result = await task.result
        postBackupTask = nil
        if case .failure(let error) = result, !(error is CancellationError), !task.isCancelled {
            await issue(.verificationFailed(planID: id))
        }
        await activity(nil)
        await changed()
        return true
    }
}
