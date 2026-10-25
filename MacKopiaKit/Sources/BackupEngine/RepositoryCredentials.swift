import BackupDomain
import Foundation
import KopiaCLI
import Secrets

/// Resolve afresh for each protected operation. S3's complete envelope lives in one Keychain item.
struct RepositoryCredentials: Sendable, CustomReflectable {
    let password: String
    let s3: KopiaS3Authentication?
    var customMirror: Mirror { Mirror(self, children: [:]) }

    static func read(repository: Repository, secrets: any SecretStore) async throws -> Self {
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
        default: throw BackupOperationError.operationFailed
        }
    }
}
