import BackupDomain
import Foundation
import KopiaCLI
import KopiaServer
import Secrets

package protocol BackupSessionOpening: Sendable {
    func open(repository: Repository, options: PlanOptions) async throws -> KopiaBackupSession
}

/// The background service composes this only after preflight/protection have authorized the operation.
package struct FilesystemBackupSessions: BackupSessionOpening {
    private let executable: URL
    private let homeDirectory: URL
    private let temporaryDirectory: URL
    private let user: String
    private let secrets: any SecretStore

    package init(
        executable: URL, homeDirectory: URL, temporaryDirectory: URL, user: String, secrets: any SecretStore
    ) {
        self.executable = executable
        self.homeDirectory = homeDirectory
        self.temporaryDirectory = temporaryDirectory
        self.user = user
        self.secrets = secrets
    }

    package func open(repository: Repository, options: PlanOptions) async throws -> KopiaBackupSession {
        guard case .filesystem = repository.kind else { throw BackupOperationError.operationFailed }
        guard let value = try await secrets.read(repository.secretRef),
            let password = String(data: value.data, encoding: .utf8), !password.isEmpty
        else { throw BackupOperationError.operationFailed }
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        return try await KopiaBackupSession.start(
            executable: executable, repositoryID: repository.id, homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: password,
            lowPriority: options.lowPriority)
    }
}
