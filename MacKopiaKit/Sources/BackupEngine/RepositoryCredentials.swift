import BackupDomain
import Foundation
import KopiaCLI
import Secrets

/// Resolve afresh for each protected operation. Each remote backend's complete envelope lives in one Keychain item.
struct RepositoryCredentials: Sendable, CustomReflectable {
    let password: String
    let s3: KopiaS3Authentication?
    var webDAV: Data? = nil
    var customMirror: Mirror { Mirror(self, children: [:]) }

    static func read(
        repository: Repository, secrets: any SecretStore,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> Self {
        guard let value = try await secrets.read(repository.secretRef) else {
            throw BackupPreflightError.backupPasswordRequired
        }
        switch repository.kind {
        case .filesystem:
            guard let password = String(data: value.data, encoding: .utf8), !password.isEmpty else {
                throw BackupOperationError.operationFailed
            }
            return Self(password: password, s3: nil)
        case .s3:
            let setup = try JSONDecoder().decode(S3Setup.self, from: value.data)
            try setup.validate()
            guard setup.kind == repository.kind else { throw BackupOperationError.operationFailed }
            return try Self(
                password: setup.password,
                s3: KopiaS3Authentication(
                    accessKey: setup.accessKey, secretKey: setup.secretKey, sessionToken: setup.sessionToken))
        case .webdav:
            let setup = try JSONDecoder().decode(WebDAVSetup.self, from: value.data)
            try setup.validate()
            guard setup.kind == repository.kind else { throw BackupOperationError.operationFailed }
            return try Self(
                password: setup.backupPassword, s3: nil,
                webDAV: KopiaWebDAVSetup.configuration(
                    repository: repository,
                    home: homeDirectory, setup: setup))
        case .sftp:
            let setup = try JSONDecoder().decode(SFTPSetup.self, from: value.data)
            try setup.validate()
            guard setup.kind == repository.kind else { throw BackupOperationError.operationFailed }
            return try Self(
                password: setup.backupPassword, s3: nil,
                webDAV: KopiaSFTPSetup.configuration(repository: repository, home: homeDirectory, setup: setup))
        }
    }
}
