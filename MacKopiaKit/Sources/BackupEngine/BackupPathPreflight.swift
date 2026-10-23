import BackupDomain
import Foundation
import SystemIntegration

/// Partial preflight only: success never authorizes starting Kopia. Recheck immediately before file operations.
package struct BackupPathPreflight: Sendable {
    private let inspector: any DirectoryInspecting

    package init(inspector: any DirectoryInspecting = LocalDirectoryInspector()) { self.inspector = inspector }

    package func validate(plan: BackupPlan, repository: Repository) async throws -> [SourcePathStatus] {
        let destination = try await validateDestination(plan: plan, repository: repository)
        return try await validateSources(plan: plan, destination: destination)
    }

    func validateDestination(plan: BackupPlan, repository: Repository) async throws -> DirectoryObservation? {
        try Task.checkCancellation()
        guard plan.repositoryID == repository.id else { throw BackupPreflightError.repositoryMismatch }
        let paths = plan.sources.map(\.path)
        try checkOverlaps(paths)
        var destination: DirectoryObservation?
        if case .filesystem(let path, let volume) = repository.kind {
            guard let volume else { throw BackupPreflightError.unboundDestination }
            for source in paths where PathRelationship.overlaps(source, path) {
                throw BackupPreflightError.sourceDestinationOverlap
            }
            do {
                let observed = try await inspector.inspectDirectory(at: path)
                try Task.checkCancellation()
                guard observed.volumeUUID == volume.uuid else { throw BackupPreflightError.destinationVolumeMismatch }
                destination = observed
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                if let error = error as? BackupPreflightError { throw error }
                if error as? VolumeInspectionError == .permissionDenied {
                    throw BackupPreflightError.destinationPermissionDenied
                }
                throw BackupPreflightError.destinationUnavailable
            }
        }
        return destination
    }

    func validateSources(plan: BackupPlan, destination: DirectoryObservation?) async throws -> [SourcePathStatus] {
        var statuses: [SourcePathStatus] = []
        var available: [DirectoryObservation] = []
        for source in plan.sources {
            try Task.checkCancellation()
            let observed: DirectoryObservation
            do {
                observed = try await inspector.inspectDirectory(at: source.path)
                try Task.checkCancellation()
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let reason: SourcePathSkipReason =
                    error as? VolumeInspectionError == .permissionDenied
                    ? .permissionDenied : .unavailable
                statuses.append(.skipped(sourceID: source.id, reason: reason))
                continue
            }
            guard observed.volumeUUID == source.volume.uuid else {
                statuses.append(.skipped(sourceID: source.id, reason: .volumeMismatch))
                continue
            }
            if let destination, Self.overlap(observed, destination) {
                throw BackupPreflightError.sourceDestinationOverlap
            }
            for previous in available where Self.overlap(previous, observed) {
                throw BackupPreflightError.overlappingSources
            }
            available.append(observed)
            statuses.append(.ready(sourceID: source.id))
        }
        try Task.checkCancellation()
        return statuses
    }

    private func checkOverlaps(_ paths: [String]) throws {
        for (index, path) in paths.enumerated() {
            try Task.checkCancellation()
            for previous in paths.prefix(index) where PathRelationship.overlaps(previous, path) {
                throw BackupPreflightError.overlappingSources
            }
        }
    }

    private static func overlap(_ lhs: DirectoryObservation, _ rhs: DirectoryObservation) -> Bool {
        PathRelationship.overlaps(
            lhs.canonicalPath, rhs.canonicalPath,
            caseSensitive: lhs.isCaseSensitive && rhs.isCaseSensitive)
    }
}
