import BackupDomain
import Foundation
import Persistence

/// Explicit execution boundary; this does not install a scheduler or connect production Kopia operations.
package struct ConfiguredJobRunner: Sendable {
    private let store: ConfigStore
    private let queue: JobQueue
    private let coordinator: BackupOperationCoordinator

    package init(store: ConfigStore, queue: JobQueue, coordinator: BackupOperationCoordinator) {
        self.store = store
        self.queue = queue
        self.coordinator = coordinator
    }

    /// Manual requests are allowed for every enabled plan. Automatic triggers must match exactly.
    @discardableResult
    package func enqueue(planID: UUID, trigger: Trigger, requestedAt: Date) async throws -> BackupJob {
        let configuration = try await store.currentConfiguration()
        let (plan, _) = try Self.resolve(planID: planID, trigger: trigger, in: configuration)
        return try await queue.enqueue(plan: plan, trigger: trigger, requestedAt: requestedAt)
    }

    /// Queue completion is awaited only after the coordinator has finished operation/protection cleanup.
    package func performNext<Value: Sendable>(
        operation: @escaping @Sendable (BackupPlan, Repository, [BackupSource]) async throws -> Value
    ) async throws -> BackupOperationResult<Value>? {
        try Task.checkCancellation()
        guard let job = await queue.takeNext() else { return nil }
        do {
            let configuration = try await store.currentConfiguration()
            let (plan, repository) = try Self.resolve(planID: job.plan.id, trigger: job.trigger, in: configuration)
            let result = try await coordinator.perform(plan: plan, repository: repository) { sources in
                let latest: BackupConfiguration
                do {
                    latest = try await store.currentConfiguration()
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw JobAdmissionError.configurationChanged
                }
                let (currentPlan, currentRepository) = try Self.resolve(
                    planID: plan.id, trigger: job.trigger, in: latest)
                guard currentPlan == plan, currentRepository == repository else {
                    throw JobAdmissionError.configurationChanged
                }
                try Task.checkCancellation()
                return try await operation(plan, repository, sources)
            }
            await queue.complete(job)
            return result
        } catch {
            await queue.complete(job)
            throw error
        }
    }

    private static func resolve(
        planID: UUID, trigger: Trigger, in configuration: BackupConfiguration
    ) throws -> (BackupPlan, Repository) {
        guard let plan = configuration.plans.first(where: { $0.id == planID }) else {
            throw JobAdmissionError.planUnavailable
        }
        guard plan.isEnabled else { throw JobAdmissionError.planDisabled }
        guard trigger == .manual || plan.triggers.contains(trigger) else {
            throw JobAdmissionError.triggerUnavailable
        }
        guard let repository = configuration.repositories.first(where: { $0.id == plan.repositoryID }) else {
            throw JobAdmissionError.repositoryUnavailable
        }
        return (plan, repository)
    }
}
