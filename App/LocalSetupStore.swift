import BackupDomain
import Foundation
import Observation

@Observable @MainActor
final class LocalSetupStore {
    let connection: AgentConnection
    var name = ""
    var sourceSelection: BackupSource?
    var destinationSelection: BackupSource?
    var source: String { sourceSelection?.path ?? "" }
    var destination: String { destinationSelection?.path ?? "" }
    var password = ""
    var confirmation = ""
    var create = true
    var useS3 = false
    var endpoint = "https://s3.amazonaws.com"
    var bucket = ""
    var prefix = ""
    var region = "us-east-1"
    var accessKey = ""
    var secretKey = ""
    var sessionToken = ""
    var s3Setup: S3Setup? {
        try? S3Setup(
            endpoint: endpoint, bucket: bucket, prefix: prefix, region: region, password: password,
            accessKey: accessKey, secretKey: secretKey, sessionToken: sessionToken)
    }
    var repositoryID: UUID?
    var revealPassword = false

    let credentialRepository: Repository?
    var needsDestination: Bool { repositoryID == nil || credentialRepository != nil }
    init(connection: AgentConnection, credentialRepository: Repository? = nil) {
        self.connection = connection; self.credentialRepository = credentialRepository
        if let repository = credentialRepository,
            case .s3(let endpoint, let bucket, let prefix, let region, _) = repository.kind
        {
            self.name = repository.name; self.endpoint = endpoint; self.bucket = bucket; self.prefix = prefix
            self.region = region ?? "us-east-1"; self.useS3 = true; self.create = false
        }
    }
    var valid: Bool {
        if credentialRepository != nil { return s3Setup != nil }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 1024
            && !source.isEmpty
            && (repositoryID != nil
                || ((useS3 ? s3Setup != nil : !destination.isEmpty) && !password.isEmpty
                    && password.utf8.count <= 65_536
                    && (!create || (password.count >= 12 && password == confirmation))))
    }
    func selectSource() { connection.chooseDirectory { self.sourceSelection = $0 } }
    func selectDestination() { connection.chooseDirectory { self.destinationSelection = $0 } }
    func generatePassword() {
        password = UUID().uuidString + UUID().uuidString; confirmation = password; revealPassword = true
    }
    func clear() {
        password = ""; confirmation = ""; revealPassword = false; accessKey = ""; secretKey = ""; sessionToken = ""
    }
    func submit(completed: @escaping () -> Void) {
        guard valid else { return }
        if let repository = credentialRepository, let setup = s3Setup {
            connection.send(.updateS3Credentials(repositoryID: repository.id, setup: setup)) {
                self.clear(); completed()
            }
            return
        }
        guard let source = sourceSelection else { return }
        if let repositoryID {
            connection.send(.createPlan(name: name, repositoryID: repositoryID, source: source), completed: completed)
            return
        }
        if useS3, let setup = s3Setup {
            connection.send(.setupS3(name: name, source: source, setup: setup, create: create)) {
                self.connection.recoveryKitRepositoryID =
                    self.connection.state?.configuration?.repositories.first {
                        $0.kind == setup.kind
                    }?.id
                self.clear(); completed()
            }
            return
        }
        guard let destination = destinationSelection else { return }
        connection.send(
            .setup(name: name, destination: destination, source: source, password: password, create: create)
        ) {
            self.connection.recoveryKitRepositoryID =
                self.connection.state?.configuration?.repositories.first {
                    if case .filesystem(let path, _) = $0.kind { return path == destination.path }
                    return false
                }?.id
            self.clear(); completed()
        }
    }
    func cancel() { connection.cancelOperation(); clear() }
}
