import BackupDomain
import Foundation

extension AutomaticBackupRuntime {
    func finished(_ job: BackupJob, result: Result<JobRun, any Error>) async {
        guard state == .running, !blockingAll, !blockedPlans.contains(job.plan.id) else { return }
        let version = generation
        let planVersion = planVersions[job.plan.id, default: 0]
        switch result {
        case .success(let run):
            await retries.reset(planID: job.plan.id)
            let paused = await queue.isPaused(job.plan.id)
            guard current(job.plan.id, generation: version, planVersion: planVersion),
                !paused, !Task.isCancelled, verification != nil || testRestore != nil || maintenance != nil
            else { return }
            let verification = verification
            let testRestore = testRestore
            let maintenance = maintenance
            let issue = issue
            let task = Task {
                if let verification {
                    do { try await verification.afterBackup(run) } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        await issue(.verificationFailed(planID: job.plan.id))
                    }
                }
                try Task.checkCancellation()
                if let testRestore {
                    do { try await testRestore.afterBackup(run) } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        await issue(.testRestoreFailed(planID: job.plan.id))
                    }
                }
                try Task.checkCancellation()
                if let maintenance, run.outcome == .succeeded {
                    do { try await maintenance(run) } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        if error as? LocalServiceIssue == .destination {
                            await issue(.ejectionFailed(planID: job.plan.id))
                        } else {
                            await issue(.maintenanceFailed(planID: job.plan.id))
                        }
                    }
                }
            }
            postBackupTask = (job.plan.id, task)
            _ = await task.result
            postBackupTask = nil
        case .failure(let error):
            guard !(error is CancellationError), !(await queue.isPaused(job.plan.id)) else {
                await retries.reset(planID: job.plan.id)
                return
            }
            do {
                let configuration = try await store.currentConfiguration()
                guard let repository = configuration.repositories.first(where: { $0.id == job.plan.repositoryID })
                else {
                    await reportFailure(job.plan.id)
                    return
                }
                guard current(job.plan.id, generation: version, planVersion: planVersion),
                    !(await queue.isPaused(job.plan.id))
                else { return }
                await retries.failed(job: job, repository: repository, error: error)
            } catch { await reportFailure(job.plan.id) }
        }
    }

}
