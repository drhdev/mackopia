import BackupDomain
import Foundation
import Persistence
import SystemIntegration

extension AutomaticBackupRuntime {
    package func pause(planID: UUID? = nil, until: Date? = nil) async throws {
        if let until {
            guard until.timeIntervalSinceReferenceDate.isFinite, until >= .distantPast, until <= .distantFuture else {
                throw DomainValidationError.invalidPlan
            }
        }
        try await control(planID: planID) {
            try await self.queue.pausePersistently(planID: planID, until: until)
        }
    }

    package func resume(planID: UUID? = nil) async throws {
        try await control(planID: planID) {
            try await self.queue.resume(planID: planID, requestedAt: self.now())
        }
    }

    package func stop(planID: UUID) async throws {
        try await control(planID: planID) { await self.queue.stop(planID: planID) }
    }

    package func pauseState(planID: UUID? = nil) async -> BackupPauseState? { await queue.pauseState(planID: planID) }

    func control(planID: UUID?, operation: @Sendable () async throws -> Void) async throws {
        guard state == .running else { throw SystemMonitoringError.unavailable }
        if let planID, configuration?.plans.contains(where: { $0.id == planID }) != true {
            throw DomainValidationError.invalidPlan
        }
        guard controls.isEmpty, monitorTask != nil else { throw RepositoryOperationError.repositoryBusy }
        let id = UUID()
        controls[planID] = id
        controlVersion &+= 1
        if let planID {
            blockedPlans.insert(planID); planVersions[planID, default: 0] &+= 1
        } else {
            blockingAll = true
            generation &+= 1
        }
        await cancelPostBackup(planID: planID)
        await scheduler.stop()
        await suppressEvents(planID: planID)
        await cancelAdmissions(planID: planID)
        if let planID { await retries.reset(planID: planID) } else { await retries.resetAll() }
        do {
            guard state == .running, controls[planID] == id else { throw CancellationError() }
            try await operation()
            if await queue.pausePersistenceFailed { throw ConfigStoreError.storageUnavailable }
        } catch {
            await finishControl(planID: planID, id: id)
            throw error
        }
        await finishControl(planID: planID, id: id)
    }

    func finishControl(planID: UUID?, id: UUID) async {
        guard state == .running, controls[planID] == id else { return }
        await suppressEvents(planID: planID)
        await cancelAdmissions(planID: planID)
        guard state == .running, controls[planID] == id else { return }
        controls.removeValue(forKey: planID)
        if let planID { blockedPlans.remove(planID) } else { blockingAll = false }
        controlVersion &+= 1
        let version = controlVersion
        await refreshEvents(version: version)
        if state == .running, controlVersion == version { await startScheduler() }
    }

    func suppressEvents(planID: UUID?) async {
        if let planID {
            await events.setSuppressed(planID: planID, true)
        } else {
            for plan in configuration?.plans ?? [] { await events.setSuppressed(planID: plan.id, true) }
        }
    }

    func refreshEvents(version: UInt64) async {
        guard state == .running, let configuration else { return }
        var plans: [BackupPlan] = []
        for plan in configuration.plans {
            let suppressed = await queue.isPaused(plan.id) || blockedPlans.contains(plan.id) || blockingAll
            guard state == .running, controlVersion == version else { return }
            await events.setSuppressed(planID: plan.id, suppressed)
            if !suppressed { plans.append(plan) }
        }
        guard state == .running, controlVersion == version else { return }
        do {
            eventConfiguration = try BackupConfiguration(repositories: configuration.repositories, plans: plans)
        } catch {
            await monitorFailed()
        }
    }

    func cancelAdmissions(planID: UUID? = nil) async {
        let workers = admissions.filter { planID == nil || $0.value.0 == planID }
        for worker in workers.values { worker.1.cancel() }
        for (id, worker) in workers where id != AutomaticAdmissionWorker.id { _ = await worker.1.result }
    }

    func cancelPostBackup(planID: UUID? = nil) async {
        guard let worker = postBackupTask, planID == nil || worker.planID == planID else { return }
        worker.task.cancel()
        _ = await worker.task.result
    }

    func controlStateFailed() async {
        guard state == .running else { return }
        await shutdown()
        await issue(.controlStateUnavailable)
    }

    /// Idempotent joining shutdown, including monitor failure and callbacks from owned workers.
    package func shutdown() async { await shutdown(failed: false) }

    func shutdown(failed: Bool) async {
        if let shutdownTask { await shutdownTask.value; return }
        state = .stopping
        generation &+= 1
        let task = Task { await self.finishShutdown(failed: failed) }
        shutdownTask = task
        await task.value
    }

    func finishShutdown(failed: Bool) async {
        await cancelPostBackup()
        await scheduler.stop()
        eventConfiguration = nil
        await events.stop()
        await cancelAdmissions()
        await retries.stop()
        let monitorWorker = monitorTask
        let drainWorker = drainTask
        let queueWorker = queueTask
        recoveryTask?.cancel()
        if AutomaticWorker.kind != .recovery { await recoveryTask?.value }
        await queue.detachPausePersistence()
        monitorWorker?.cancel()
        drainWorker?.cancel()
        queueWorker?.cancel()
        await queue.pause()
        await queue.cancelPauseTimers()
        if AutomaticWorker.kind != .monitor { await monitorWorker?.value }
        if AutomaticWorker.kind != .drain { await drainWorker?.value }
        if AutomaticWorker.kind != .queue { await queueWorker?.value }
        if await queue.pausePersistenceFailed {
            state = .controlStateUnavailable
        } else {
            state = failed ? .monitorUnavailable : .stopped
        }
    }
}

enum AutomaticAdmissionWorker {
    @TaskLocal static var id: UUID?
}
