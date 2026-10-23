import Foundation

/// Share one instance across all engine operations. This is admission control, not a waiting queue.
package actor RepositoryOperationGate {
    private let maximumConcurrentOperations: Int
    private var activeRepositories: Set<UUID> = []

    package init(maximumConcurrentOperations: Int = 1) throws {
        guard maximumConcurrentOperations > 0 else { throw RepositoryOperationError.invalidLimit }
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }

    /// Keep the operation alive through child-process cleanup/reaping, including on cancellation.
    /// A nested operation for the same repository is rejected rather than deadlocking.
    package func withOperation<Result: Sendable>(
        repositoryID: UUID,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard !activeRepositories.contains(repositoryID) else { throw RepositoryOperationError.repositoryBusy }
        guard activeRepositories.count < maximumConcurrentOperations else {
            throw RepositoryOperationError.concurrencyLimitReached
        }
        activeRepositories.insert(repositoryID)
        defer { activeRepositories.remove(repositoryID) }
        // Actor reentrancy allows unrelated repositories to enter up to the configured limit.
        try Task.checkCancellation()
        return try await operation()
    }
}
