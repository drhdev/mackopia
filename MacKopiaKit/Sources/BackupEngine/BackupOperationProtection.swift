import BackupDomain

/// Trusted adapter: arm live monitoring of all relevant volumes before invoking operation.
/// On disappearance, cancel operation and await its process cleanup/reaping before returning.
/// Monitoring must remain armed through that cleanup, and must be disarmed on every exit.
package protocol BackupOperationProtecting: Sendable {
    func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result
}

/// No production operation may proceed until a real monitoring adapter is supplied.
package struct UnavailableBackupOperationProtection: BackupOperationProtecting {
    package init() {}

    package func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        throw BackupOperationError.protectionUnavailable
    }
}
