import BackupDomain
import Foundation
import KopiaCLI
import Secrets

package protocol MaintenanceInspecting: Sendable {
    func inspect(repository: Repository, lowPriority: Bool) async throws -> KopiaMaintenanceInfo
}

package protocol MaintenanceRunning: Sendable {
    func runFull(repository: Repository, lowPriority: Bool) async throws
}

/// Composed only by the background service, with the same isolated state as backups.
package struct FilesystemMaintenanceInspection: MaintenanceInspecting, MaintenanceRunning {
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

    package func inspect(repository: Repository, lowPriority: Bool) async throws -> KopiaMaintenanceInfo {
        let credentials = try await credentials(repository: repository)
        return try await KopiaMaintenanceReader().read(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory),
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: credentials.password,
            lowPriority: lowPriority, s3: credentials.s3)
    }

    package func runFull(repository: Repository, lowPriority: Bool) async throws {
        let credentials = try await credentials(repository: repository)
        try await KopiaMaintenanceRunner().runFull(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory),
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: credentials.password,
            lowPriority: lowPriority, s3: credentials.s3)
    }

    private func credentials(repository: Repository) async throws -> RepositoryCredentials {
        try Task.checkCancellation()
        let credentials = try await RepositoryCredentials.read(repository: repository, secrets: secrets)
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        return credentials
    }
}
