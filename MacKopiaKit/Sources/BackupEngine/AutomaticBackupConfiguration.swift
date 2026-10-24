import BackupDomain
import Foundation
import Persistence

extension AutomaticBackupRuntime {
    /// Apply the store's accepted configuration. The caller owns explicit disk load/save; no file
    /// watcher can silently recover safe mode. Changed work is cancelled through normal cleanup.
    package func reloadConfiguration() async throws {
        try await control(planID: nil) {
            await self.queue.holdForConfiguration(true)
            do {
                try await self.replaceConfiguration()
            } catch {
                // A partially reconciled configuration must never reopen admissions.
                await self.configurationFailed()
                throw error
            }
        }
        if state == .running { await queue.holdForConfiguration(false) }
    }

    private func replaceConfiguration() async throws {
        let version = generation
        let replacement = try await store.currentConfiguration()
        try checkReload(version)
        let anchors = try await historySchedule?.scheduleAnchors(plans: replacement.plans, before: now()) ?? [:]
        try checkReload(version)
        let old = configuration
        let repositories = Dictionary(uniqueKeysWithValues: replacement.repositories.map { ($0.id, $0) })
        let plans = Dictionary(uniqueKeysWithValues: replacement.plans.map { ($0.id, $0) })
        for plan in old?.plans ?? [] {
            let previousRepository = old?.repositories.first { $0.id == plan.repositoryID }
            if plans[plan.id] != plan || repositories[plan.repositoryID] != previousRepository {
                await queue.stop(planID: plan.id)
                try checkReload(version)
            }
            if plans[plan.id] == nil, await queue.pauseState(planID: plan.id) != nil {
                try await queue.resume(planID: plan.id, requestedAt: now())
                try checkReload(version)
            }
        }
        // A concurrent store edit requires another reload, never a mixed accepted snapshot.
        guard try await store.currentConfiguration() == replacement else {
            throw ConfigStoreError.storageChanged
        }
        try checkReload(version)
        try await scheduler.replace(plans: replacement.plans, lastRuns: anchors)
        try checkReload(version)
        await events.replace(configuration: replacement)
        try checkReload(version)
        configuration = replacement
        eventConfiguration = nil
        planVersions = planVersions.filter { plans[$0.key] != nil }
    }

    private func checkReload(_ version: UInt64) throws {
        try Task.checkCancellation()
        guard state == .running, generation == version else { throw CancellationError() }
    }

    private func configurationFailed() async {
        guard state == .running else { return }
        await shutdown()
        if state == .stopped { state = .configurationUnavailable }
        await issue(.configurationUnavailable)
    }
}
