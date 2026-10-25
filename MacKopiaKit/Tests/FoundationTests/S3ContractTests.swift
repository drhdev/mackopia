import BackupDomain
import Foundation
import Secrets
import Testing

@testable import AgentProtocol
@testable import BackupEngine
@testable import KopiaCLI
@testable import KopiaServer

struct S3ContractTests {
    @Test(arguments: [
        "http://storage.invalid", "https://user:secret@storage.invalid", "https://storage.invalid/path",
        "https://storage.invalid?token=secret", "https://storage.invalid/#fragment", "http://localhost:9000",
    ])
    func rejectsUnsafeEndpoints(endpoint: String) {
        #expect(throws: DomainValidationError.invalidRepository) {
            try setup(endpoint: endpoint)
        }
    }

    @Test func requestValidatesDecodedCredentialsAndRedactsReflection() throws {
        let setup = try setup()
        let source = try BackupSource(
            path: "/tmp/source",
            volume: VolumeIdentity(
                uuid: "11111111-1111-1111-1111-111111111111", name: "Temporary", isRemovable: false, isNetwork: false))
        let request = AgentRequest(.setupS3(name: "S3", source: source, setup: setup, create: true))
        let decoded = try AgentWirePacket(request).decode(AgentRequest.self)
        try decoded.validate()
        for value in [setup.password, setup.accessKey, setup.secretKey, setup.sessionToken] {
            #expect(!String(reflecting: setup).contains(value))
            #expect(!String(reflecting: decoded).contains(value))
        }
        let data = try JSONEncoder().encode(setup)
        var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        document["secretKey"] = ""
        let invalid = try JSONDecoder().decode(S3Setup.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(throws: DomainValidationError.invalidRepository) {
            try AgentRequest(.updateS3Credentials(repositoryID: UUID(), setup: invalid)).validate()
        }
    }

    @Test func credentialsOnlyReachExplicitChildEnvironment() throws {
        let auth = try KopiaS3Authentication(
            accessKey: "access-marker", secretKey: "secret-marker", sessionToken: "token-marker")
        let root = URL(fileURLWithPath: "/tmp/s3-test")
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        let context = KopiaExecutionContext(
            executable: root.appendingPathComponent("kopia"), paths: paths,
            temporaryDirectory: root, user: "test", configuration: .file, backupPassword: "password-marker", s3: auth)
        let cli = context.request(for: .repositoryAccess)
        let server = try KopiaServerConfiguration(
            executable: root.appendingPathComponent("kopia"), repositoryID: UUID(),
            homeDirectory: root, temporaryDirectory: root, user: "test", backupPassword: "password-marker", s3: auth)
        for (key, value) in auth.environment {
            #expect(cli.environment[key] == value)
            #expect(server.environment[key] == value)
            #expect(!cli.arguments.joined().contains(value))
            #expect(!server.arguments.joined().contains(value))
            #expect(!String(reflecting: auth).contains(value))
        }
    }

    @Test(arguments: ["valid", "secretAccessKey", "accessKeyID", "sessionToken", "endpoint", "prefix", "doNotUseTLS"])
    func bindingRejectsCredentialsAndDestinationChanges(change: String) throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = try setup()
        let repository = try Repository(
            name: "S3", kind: setup.kind,
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "host"), secretRef: SecretRef())
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var storage = try KopiaS3Setup.storage(repository: repository)
        if change != "valid" { storage[change] = .string("unexpected") }
        let document: [String: Any] = [
            "storage": ["type": "s3", "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(storage))],
            "username": "test", "hostname": "host", "enableActions": false,
        ]
        let file = paths.configurationDirectory.appendingPathComponent("repository.config")
        try JSONSerialization.data(withJSONObject: document).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if change == "valid" {
            try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: root)
        } else {
            #expect(throws: KopiaProcessError.invalidRequest) {
                try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: root)
            }
        }
    }

    @Test func keychainEnvelopeCannotBeReusedForAnotherDestination() async throws {
        let setup = try setup()
        let ref = SecretRef()
        let store = ServiceTestSecrets()
        try await store.write(SecretValue(data: JSONEncoder().encode(setup)), for: ref)
        let repository = try Repository(
            name: "S3", kind: setup.kind,
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "host"), secretRef: ref)
        let credentials = try await RepositoryCredentials.read(repository: repository, secrets: store)
        #expect(credentials.password == setup.password)
        let other = try Repository(
            name: "Other",
            kind: .s3(
                endpoint: setup.endpoint, bucket: "other", prefix: setup.prefix,
                region: setup.region, objectLock: false), identity: repository.identity, secretRef: ref)
        await #expect(throws: BackupOperationError.operationFailed) {
            try await RepositoryCredentials.read(repository: other, secrets: store)
        }
    }

    private func setup(endpoint: String = "https://s3.example.invalid") throws -> S3Setup {
        try S3Setup(
            endpoint: endpoint, bucket: "bucket", prefix: "backups/", region: "us-east-1",
            password: "password-marker-123", accessKey: "access-marker", secretKey: "secret-marker",
            sessionToken: "token-marker")
    }
}
