import BackupDomain
import KopiaCLI
import Secrets

/// First two preflight gates only. Success is not permission to open a destination or start a snapshot.
package struct BackupPrerequisitePreflight: Sendable {
    private let binary: any KopiaBinaryVerifying
    private let secrets: any SecretStore

    package init(binary: any KopiaBinaryVerifying, secrets: any SecretStore) {
        self.binary = binary
        self.secrets = secrets
    }

    package func validate(repository: Repository) async throws {
        try await validateBinary()
        try await validateBackupPassword(repository: repository)
    }

    func validateBinary() async throws {
        try Task.checkCancellation()
        do {
            try await binary.verify()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error as? KopiaBinaryVerificationError ?? .probeFailed
        }
        try Task.checkCancellation()
    }

    func validateBackupPassword(repository: Repository) async throws {
        try Task.checkCancellation()
        // Never return/cache the value in a preflight report. The eventual operation resolves it afresh.
        let present: Bool
        do {
            if case .s3 = repository.kind {
                _ = try await RepositoryCredentials.read(repository: repository, secrets: secrets)
                present = true
            } else {
                present = try await secrets.read(repository.secretRef) != nil
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error as? SecretStoreError ?? .unavailable
        }
        if !present {
            try Task.checkCancellation()
            throw BackupPreflightError.backupPasswordRequired
        }
        try Task.checkCancellation()
    }
}
