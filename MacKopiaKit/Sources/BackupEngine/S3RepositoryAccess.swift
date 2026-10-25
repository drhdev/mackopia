import BackupDomain
import Foundation
import KopiaCLI
import Secrets

/// Fresh authenticated repository read under the eventual operation's reservation.
struct S3RepositoryAccess: RepositoryAccessChecking {
    let executable: URL
    let home: URL
    let temporary: URL
    let secrets: any SecretStore
    func checkAccess(to repository: Repository) async throws -> PreflightAccessStatus {
        guard case .s3 = repository.kind else { return .unknown }
        let credentials = try await RepositoryCredentials.read(repository: repository, secrets: secrets)
        guard let authentication = credentials.s3 else { return .denied }
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: home)
        return try await KopiaRepositoryProbe().check(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home),
            temporaryDirectory: temporary, user: NSUserName(), password: credentials.password,
            authentication: authentication) ? .verified : .denied
    }
}
