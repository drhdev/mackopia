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
        let password = try await password(repository: repository)
        return try await KopiaMaintenanceReader().read(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory),
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: password, lowPriority: lowPriority)
    }

    package func runFull(repository: Repository, lowPriority: Bool) async throws {
        let password = try await password(repository: repository)
        try await KopiaMaintenanceRunner().runFull(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory),
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: password, lowPriority: lowPriority)
    }

    private func password(repository: Repository) async throws -> String {
        try Task.checkCancellation()
        guard case .filesystem = repository.kind,
            let value = try await secrets.read(repository.secretRef),
            let password = String(data: value.data, encoding: .utf8), !password.isEmpty
        else { throw BackupOperationError.operationFailed }
        try Task.checkCancellation()
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        return password
    }
}
