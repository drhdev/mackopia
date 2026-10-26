import BackupDomain
import Foundation
import KopiaCLI
import Secrets

package protocol SnapshotVerifying: Sendable {
    func verify(repository: Repository, snapshotIDs: [String], filesPercent: Int, lowPriority: Bool) async throws
}

/// Only composed by the background service after protected preflight admission.
package struct FilesystemSnapshotVerification: SnapshotVerifying {
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

    package func verify(
        repository: Repository, snapshotIDs: [String], filesPercent: Int, lowPriority: Bool
    ) async throws {
        try Task.checkCancellation()
        let request = try KopiaSnapshotVerification(snapshotIDs: snapshotIDs, filesPercent: filesPercent)
        let credentials = try await RepositoryCredentials.read(
            repository: repository, secrets: secrets, homeDirectory: homeDirectory)
        let password = credentials.password
        try Task.checkCancellation()
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: homeDirectory)
        try await KopiaSnapshotVerifier().verify(
            request, executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory),
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: password, lowPriority: lowPriority,
            s3: credentials.s3, webDAV: credentials.webDAV)
    }
}
