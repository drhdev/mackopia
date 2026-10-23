import BackupDomain
import Foundation
import KopiaCLI
import Secrets
import SystemIntegration

/// Diagnostic orchestration only. It neither opens a server nor starts backups by itself.
package struct BackupPreflight: Sendable {
    private let prerequisites: BackupPrerequisitePreflight
    private let paths: BackupPathPreflight
    private let destination: FilesystemDestinationPreflight
    private let repositoryAccess: any RepositoryAccessChecking
    private let sourceAccess: any SourceAccessChecking
    private let environment: any RunEnvironmentSampling
    private let gate: RepositoryOperationGate

    package init(
        prerequisites: BackupPrerequisitePreflight, gate: RepositoryOperationGate,
        paths: BackupPathPreflight = BackupPathPreflight(),
        destination: FilesystemDestinationPreflight = FilesystemDestinationPreflight(),
        repositoryAccess: any RepositoryAccessChecking = UnknownPreflightObservations(),
        sourceAccess: any SourceAccessChecking = UnknownPreflightObservations(),
        environment: any RunEnvironmentSampling = LocalRunEnvironmentSampler()
    ) {
        self.prerequisites = prerequisites
        self.gate = gate
        self.paths = paths
        self.destination = destination
        self.repositoryAccess = repositoryAccess
        self.sourceAccess = sourceAccess
        self.environment = environment
    }

    package func evaluate(plan: BackupPlan, repository: Repository) async throws -> BackupPreflightReport {
        do {
            return try await withReservedEvaluation(plan: plan, repository: repository) { $0 }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return BackupPreflightReport(
                outcome: .blocked,
                checks: [.init(step: .repositoryExclusion, status: .blocked, issue: Self.issue(error))], sources: [])
        }
    }

    /// Internal scope boundary: the callback must await all operation cleanup before returning.
    func withReservedEvaluation<Result: Sendable>(
        plan: BackupPlan, repository: Repository,
        operation: @Sendable (BackupPreflightReport) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard plan.repositoryID == repository.id else {
            return try await operation(
                BackupPreflightReport(
                    outcome: .blocked,
                    checks: [.init(step: .configuration, status: .blocked, issue: .configuration(.repositoryMismatch))],
                    sources: []))
        }
        return try await gate.withOperation(repositoryID: repository.id) {
            let report = try await evaluateReserved(plan: plan, repository: repository)
            let result = try await operation(report)
            // Cleanup may suspend even after the operation returned. Do not turn a late cancel into success.
            try Task.checkCancellation()
            return result
        }
    }

    /// Only call inside withReservedEvaluation, after live protection has been armed.
    func reevaluateReserved(plan: BackupPlan, repository: Repository) async throws -> BackupPreflightReport {
        try await evaluateReserved(plan: plan, repository: repository)
    }

    /// Last point-in-time identity check. The monitor must already cover subsequent accesses.
    func recheckIdentities(plan: BackupPlan, repository: Repository, report: BackupPreflightReport) async throws {
        let statuses = try await paths.validate(plan: plan, repository: repository)
        guard statuses == report.sources else { throw BackupOperationError.identitiesChanged }
        try Task.checkCancellation()
    }

    private func evaluateReserved(plan: BackupPlan, repository: Repository) async throws -> BackupPreflightReport {
        var checks: [BackupPreflightCheck] = []
        var sources: [SourcePathStatus] = []
        var step = BackupPreflightCheck.Step.binary
        func report(
            _ outcome: BackupPreflightReport.Outcome, _ status: BackupPreflightCheck.Status,
            _ issue: BackupPreflightIssue
        ) -> BackupPreflightReport {
            BackupPreflightReport(
                outcome: outcome, checks: checks + [.init(step: step, status: status, issue: issue)], sources: sources)
        }
        func passed(_ step: BackupPreflightCheck.Step) -> BackupPreflightCheck {
            .init(step: step, status: .passed, issue: nil)
        }
        do {
            try await prerequisites.validateBinary()
            checks.append(passed(step))
            step = .backupPassword
            try await prerequisites.validateBackupPassword(repository: repository)
            checks.append(passed(step))
            step = .destinationIdentity
            let observed = try await paths.validateDestination(plan: plan, repository: repository)
            checks.append(observed == nil ? .init(step: step, status: .skipped, issue: nil) : passed(step))
            step = .destinationAccess
            var capacity: DestinationCapacityStatus?
            if case .filesystem(let path, let volume) = repository.kind {
                guard let volume else { throw BackupPreflightError.unboundDestination }
                capacity = try await destination.validate(path: path, expectedVolume: volume)
            } else {
                let access = try await repositoryAccess.checkAccess(to: repository)
                try Task.checkCancellation()
                switch access {
                case .verified: break
                case .denied: return report(.blocked, .blocked, .destinationAccessDenied)
                case .unknown: return report(.blocked, .blocked, .destinationAccessUnknown)
                }
            }
            checks.append(passed(step))
            step = .destinationCapacity
            switch capacity {
            case .insufficientSpace: return report(.blocked, .blocked, .insufficientDestinationSpace)
            case .lowSpaceWarning:
                checks.append(.init(step: step, status: .warning, issue: .lowDestinationSpace))
            case .sufficient: checks.append(passed(step))
            case nil:
                // Remote providers do not expose a local volume capacity observation.
                checks.append(.init(step: step, status: .skipped, issue: nil))
            }
            step = .sourceIdentity
            sources = try await paths.validateSources(plan: plan, destination: observed)
            let readyIDs = Set(
                sources.compactMap { status -> UUID? in
                    if case .ready(let id) = status { id } else { nil }
                })
            guard !readyIDs.isEmpty else { return report(.skipped, .skipped, .noAvailableSources) }
            checks.append(
                .init(
                    step: step, status: readyIDs.count == sources.count ? .passed : .warning,
                    issue: readyIDs.count == sources.count ? nil : .sourcesSkipped))
            step = .sourceAccess
            let access = try await sourceAccess.checkAccess(to: plan.sources.filter { readyIDs.contains($0.id) })
            try Task.checkCancellation()
            switch access {
            case .verified: checks.append(passed(step))
            case .denied: return report(.blocked, .blocked, .sourceAccessDenied)
            case .unknown: return report(.blocked, .blocked, .sourceAccessUnknown)
            }
            step = .runConditions
            let sampled = try await environment.sample()
            try Task.checkCancellation()
            switch RunConditionEvaluator.evaluate(plan.conditions, environment: sampled) {
            case .allowed: checks.append(passed(step))
            case .skipped(let reason): return report(.skipped, .skipped, .conditions(reason))
            }
            checks.append(passed(.repositoryExclusion))
            try Task.checkCancellation()
            return BackupPreflightReport(outcome: .checksPassed, checks: checks, sources: sources)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return report(.blocked, .blocked, Self.issue(error))
        }
    }

    private static func issue(_ error: any Error) -> BackupPreflightIssue {
        switch error {
        case let error as KopiaBinaryVerificationError: .binary(error)
        case let error as SecretStoreError: .keychain(error)
        case let error as BackupPreflightError: .configuration(error)
        case let error as RepositoryOperationError: .operation(error)
        default: .checkFailed
        }
    }
}
