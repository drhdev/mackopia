import BackupDomain

/// No reusable start token: a fresh evaluation, live protection and cleanup share one reservation.
package struct BackupOperationCoordinator: Sendable {
    private let preflight: BackupPreflight
    private let protection: any BackupOperationProtecting

    package init(
        preflight: BackupPreflight,
        protection: any BackupOperationProtecting = UnavailableBackupOperationProtection()
    ) {
        self.preflight = preflight
        self.protection = protection
    }

    /// The trusted operation must use only supplied sources, resolve secrets afresh and await all
    /// child-process cleanup/reaping even on cancellation. Callback completion alone is not snapshot success.
    package func perform<Value: Sendable>(
        plan: BackupPlan, repository: Repository,
        operation: @escaping @Sendable ([BackupSource]) async throws -> Value
    ) async throws -> BackupOperationResult<Value> {
        do {
            return try await preflight.withReservedEvaluation(plan: plan, repository: repository) { initial in
                guard initial.outcome == .checksPassed else { return .notStarted(initial) }
                let initiallyReady = Set(
                    initial.sources.compactMap { status in
                        if case .ready(let id) = status { id } else { nil }
                    })
                let protectedSources = plan.sources.filter { initiallyReady.contains($0.id) }
                return try await protection.withProtection(sources: protectedSources, repository: repository) {
                    // Arming monitoring may suspend. Never use the earlier report as authorization.
                    let fresh = try await preflight.reevaluateReserved(plan: plan, repository: repository)
                    guard fresh.outcome == .checksPassed else { return .notStarted(fresh) }
                    try await preflight.recheckIdentities(plan: plan, repository: repository, report: fresh)
                    let readyIDs = Set(
                        fresh.sources.compactMap { status in
                            if case .ready(let id) = status { id } else { nil }
                        })
                    // A source that appeared while monitoring was armed is not covered by this session.
                    guard readyIDs.isSubset(of: initiallyReady) else { throw BackupOperationError.identitiesChanged }
                    let sources = plan.sources.filter { readyIDs.contains($0.id) }
                    try Task.checkCancellation()
                    let value = try await operation(sources)
                    try Task.checkCancellation()
                    return .completed(value: value, report: fresh)
                }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // Preserve only static typed errors. Never forward arbitrary adapter/process error payloads.
            if let error = error as? RepositoryOperationError { throw error }
            if let error = error as? BackupPreflightError { throw error }
            if let error = error as? BackupOperationError { throw error }
            if let error = error as? JobAdmissionError { throw error }
            throw BackupOperationError.operationFailed
        }
    }
}

package enum BackupOperationResult<Value: Sendable>: Sendable {
    case notStarted(BackupPreflightReport)
    case completed(value: Value, report: BackupPreflightReport)
}
