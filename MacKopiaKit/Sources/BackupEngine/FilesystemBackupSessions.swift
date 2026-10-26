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
        let credentials = try await RepositoryCredentials.read(
            repository: repository, secrets: secrets, homeDirectory: homeDirectory)
        let password = credentials.password
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        return try await KopiaBackupSession.start(
            executable: executable, repositoryID: repository.id, homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: password,
            lowPriority: options.lowPriority, s3: credentials.s3, webDAV: credentials.webDAV)
    }
}
