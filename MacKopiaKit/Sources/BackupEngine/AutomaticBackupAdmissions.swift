import BackupDomain
import Foundation

extension AutomaticBackupRuntime {
    package func enqueue(planID: UUID) async throws {
        try await submit(
            ScheduledRequest(planID: planID, trigger: .manual, requestedAt: now()), evidence: nil, retry: false)
    }

    func admit(_ request: ScheduledRequest, evidence: (BackupPlan, Repository)?, retry: Bool) async {
        do { try await submit(request, evidence: evidence, retry: retry) } catch {
            if error as? JobAdmissionError != .planPaused, !(error is CancellationError) {
                await reportAdmission(request.planID)
            }
        }
    }

    /// Registration precedes suspension. Controls cancel and join these workers before clearing jobs,
    /// closing the gap between a suspended ConfigStore lookup and final atomic queue insertion.
    func submit(_ request: ScheduledRequest, evidence: (BackupPlan, Repository)?, retry: Bool) async throws {
        guard state == .running, !blockingAll, !blockedPlans.contains(request.planID) else { throw CancellationError() }
        let id = UUID()
        let version = generation
        let planVersion = planVersions[request.planID, default: 0]
        let task = Task {
            try await AutomaticAdmissionWorker.$id.withValue(id) {
                try await self.executeAdmission(
                    request, evidence: evidence, retry: retry, version: version, planVersion: planVersion)
            }
        }
        admissions[id] = (request.planID, task)
        defer { admissions.removeValue(forKey: id) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func executeAdmission(
        _ request: ScheduledRequest, evidence: (BackupPlan, Repository)?, retry: Bool,
        version: UInt64, planVersion: UInt64
    ) async throws {
        guard current(request.planID, generation: version, planVersion: planVersion) else { throw CancellationError() }
        guard !(await queue.isPaused(request.planID)) else { throw JobAdmissionError.planPaused }
        if !retry { await retries.reset(planID: request.planID) }
        guard current(request.planID, generation: version, planVersion: planVersion) else { throw CancellationError() }
        if let (plan, repository) = evidence {
            _ = try await runner.enqueue(
                plan: plan, repository: repository, trigger: request.trigger, requestedAt: request.requestedAt)
        } else {
            _ = try await runner.enqueue(
                planID: request.planID, trigger: request.trigger, requestedAt: request.requestedAt)
        }
    }

    func current(_ id: UUID, generation: UInt64, planVersion: UInt64) -> Bool {
        state == .running && self.generation == generation && planVersions[id, default: 0] == planVersion
            && !blockingAll && !blockedPlans.contains(id) && !Task.isCancelled
    }

    func reportAdmission(_ id: UUID) async {
        if state == .running, !blockingAll, !blockedPlans.contains(id), !(await queue.isPaused(id)) {
            await issue(.admissionRejected(planID: id))
        }
    }

    func reportFailure(_ id: UUID) async {
        if state == .running, !blockingAll, !blockedPlans.contains(id), !(await queue.isPaused(id)) {
            await issue(.backupFailed(planID: id))
        }
    }

}
