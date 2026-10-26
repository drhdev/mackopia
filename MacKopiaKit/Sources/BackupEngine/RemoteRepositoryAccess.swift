import BackupDomain
import Foundation
import KopiaCLI
import Secrets

/// Fresh authenticated repository read under the eventual operation's reservation.
struct RemoteRepositoryAccess: RepositoryAccessChecking {
    let executable: URL
    let home: URL
    let temporary: URL
    let secrets: any SecretStore
    func checkAccess(to repository: Repository) async throws -> PreflightAccessStatus {
        switch repository.kind {
        case .s3, .webdav: break
        default: return .unknown
        }
        let credentials = try await RepositoryCredentials.read(
            repository: repository, secrets: secrets, homeDirectory: home)
        guard credentials.s3 != nil || credentials.webDAV != nil else { return .unknown }
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: home)
        return try await KopiaRepositoryProbe().check(
            executable: executable,
            paths: KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home),
            temporaryDirectory: temporary, user: NSUserName(), password: credentials.password,
            authentication: credentials.s3, webDAV: credentials.webDAV) ? .verified : .denied
    }
}
