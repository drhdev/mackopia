import BackupDomain

package enum PreflightAccessStatus: Sendable, Equatable { case verified, denied, unknown }

/// The adapter must verify configured backend credentials and authenticated read/write access.
package protocol RepositoryAccessChecking: Sendable {
    func checkAccess(to repository: Repository) async throws -> PreflightAccessStatus
}

/// Verified includes any required FDA/TCC access for every supplied, currently available source.
package protocol SourceAccessChecking: Sendable {
    func checkAccess(to sources: [BackupSource]) async throws -> PreflightAccessStatus
}

package protocol RunEnvironmentSampling: Sendable {
    func sample() async throws -> RunEnvironment
}

/// Missing live adapters must never make an unverified check pass.
package struct UnknownPreflightObservations: RepositoryAccessChecking, SourceAccessChecking, RunEnvironmentSampling {
    package init() {}
    package func checkAccess(to repository: Repository) async throws -> PreflightAccessStatus { .unknown }
    package func checkAccess(to sources: [BackupSource]) async throws -> PreflightAccessStatus { .unknown }
    package func sample() async throws -> RunEnvironment { try RunEnvironment() }
}
