import BackupDomain
import Foundation
import KopiaCLI
import Persistence
import SystemIntegration

/// Inspection and execution share the backup reservation; observations never authorize a later run.
package struct MaintenanceCoordinator: Sendable {
    private let store: ConfigStore
    private let coordinator: BackupOperationCoordinator
    package enum FullRun: Sendable, Equatable {
        case skipped(KopiaMaintenanceInfo.FullMaintenance)
        case completed
    }

    private let runner: (any MaintenanceRunning)?
    private let inspector: any MaintenanceInspecting
    private let sleep: any SleepPreventing
    private let now: @Sendable () -> Date

    package init(
        store: ConfigStore, coordinator: BackupOperationCoordinator, inspector: any MaintenanceInspecting,
        runner: (any MaintenanceRunning)? = nil,
        sleep: any SleepPreventing = LocalSleepPreventer(), now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.coordinator = coordinator
        self.inspector = inspector
        self.runner = runner
        self.sleep = sleep
        self.now = now
    }

    /// Nil means preflight declined the read. No owner is claimed or changed by inspection.
    package func inspect(planID: UUID) async throws -> KopiaMaintenanceInfo.FullMaintenance? {
        try await evaluate(planID: planID, execute: false)?.observation
    }

    /// Nil means preflight declined. A completed command is not durable maintenance evidence.
    package func runDueFull(planID: UUID) async throws -> FullRun? {
        guard runner != nil else { throw BackupOperationError.operationFailed }
        guard let result = try await evaluate(planID: planID, execute: true) else { return nil }
        return result.ran ? .completed : .skipped(result.observation)
    }

    private struct Evaluation: Sendable {
        let observation: KopiaMaintenanceInfo.FullMaintenance
        let ran: Bool
    }

    private func evaluate(planID: UUID, execute: Bool) async throws -> Evaluation? {
        try Task.checkCancellation()
        let configuration = try await store.currentConfiguration()
        guard let plan = configuration.plans.first(where: { $0.id == planID }) else {
            throw JobAdmissionError.planUnavailable
        }
        guard plan.isEnabled else { throw JobAdmissionError.planDisabled }
        guard let repository = configuration.repositories.first(where: { $0.id == plan.repositoryID }) else {
            throw JobAdmissionError.repositoryUnavailable
        }
        guard case .filesystem = repository.kind else { throw BackupOperationError.operationFailed }
        let result = try await coordinator.perform(plan: plan, repository: repository) { _ in
            guard try await store.currentConfiguration() == configuration else {
                throw JobAdmissionError.configurationChanged
            }
            try Task.checkCancellation()
            let assertion = try sleep.acquire()
            defer { assertion.release() }
            let info = try await inspector.inspect(repository: repository, lowPriority: plan.options.lowPriority)
            guard try await store.currentConfiguration() == configuration else {
                throw JobAdmissionError.configurationChanged
            }
            try Task.checkCancellation()
            let observation = try info.fullMaintenance(identity: repository.identity, at: now())
            guard execute, observation == .due, let runner else {
                return Evaluation(observation: observation, ran: false)
            }
            try await runner.runFull(repository: repository, lowPriority: plan.options.lowPriority)
            guard try await store.currentConfiguration() == configuration else {
                throw JobAdmissionError.configurationChanged
            }
            try Task.checkCancellation()
            return Evaluation(observation: observation, ran: true)
        }
        guard case .completed(let observation, _) = result else { return nil }
        return observation
    }
}
