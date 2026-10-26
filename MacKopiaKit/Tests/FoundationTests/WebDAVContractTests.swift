import BackupDomain
import Foundation
import Secrets
import Testing

@testable import AgentProtocol
@testable import BackupEngine
@testable import KopiaCLI
@testable import KopiaServer

struct WebDAVContractTests {
    @Test(arguments: [
        "http://storage.invalid/dav", "http://localhost:9000", "https://user:secret@storage.invalid",
        "https://storage.invalid?token=secret", "https://storage.invalid/#fragment", "https://storage.invalid:99999",
    ])
    func rejectsUnsafeEndpoints(endpoint: String) throws {
        let url = try #require(URL(string: endpoint))
        #expect(throws: DomainValidationError.invalidRepository) {
            try WebDAVSetup(url: url, username: "user", password: "password", backupPassword: "backup-password")
        }
    }

    @Test func decodedRequestsValidateAndHideCredentials() throws {
        let setup = try setup()
        let source = try BackupSource(
            path: "/tmp/source",
            volume: VolumeIdentity(
                uuid: "11111111-1111-1111-1111-111111111111", name: "Temporary", isRemovable: false, isNetwork: false))
        let request = AgentRequest(.setupWebDAV(name: "WebDAV", source: source, setup: setup, create: true))
        let decoded = try AgentWirePacket(request).decode(AgentRequest.self)
        try decoded.validate()
        for secret in [setup.username, setup.password, setup.backupPassword] {
            #expect(!String(reflecting: setup).contains(secret))
            #expect(!String(reflecting: decoded).contains(secret))
        }
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(setup)) as? [String: Any])
        document["password"] = ""
        let invalid = try JSONDecoder().decode(WebDAVSetup.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(throws: DomainValidationError.invalidRepository) {
            try AgentRequest(.updateWebDAVCredentials(repositoryID: UUID(), setup: invalid)).validate()
        }
        #expect(throws: DomainValidationError.invalidRepository) {
            try WebDAVSetup(url: setup.url, username: "user:name", password: "password", backupPassword: "backup")
        }
    }

    @Test func payloadIsOnlyInMemoryAndCommandsNeverMutateConnections() throws {
        let setup = try setup()
        let root = URL(fileURLWithPath: "/tmp/webdav-test")
        let repository = try repository(kind: setup.kind)
        let payload = try KopiaWebDAVSetup.configuration(repository: repository, home: root, setup: setup)
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
        let context = KopiaExecutionContext(
            executable: root.appendingPathComponent("kopia"), paths: paths,
            temporaryDirectory: root, user: "test", configuration: .webDAV(payload),
            backupPassword: setup.backupPassword)
        let server = try KopiaServerConfiguration(
            executable: root.appendingPathComponent("kopia"),
            repositoryID: repository.id, homeDirectory: root, temporaryDirectory: root, user: "test",
            backupPassword: setup.backupPassword, configuration: .webDAV(payload))
        for command in [
            KopiaCommand.repositoryStatus, .repositoryAccess, .maintenanceInfo,
            .initializeBalancedPolicy, .claimMaintenanceOwner, .maintenanceFull,
        ] {
            let request = context.request(for: command)
            #expect(request.webDAVConfiguration == payload)
            #expect(request.repositoryDirectory == paths.configurationDirectory)
            #expect(!request.arguments.contains(where: { $0.hasPrefix("--config-file=") }))
            for secret in [setup.username, setup.password, setup.backupPassword] {
                #expect(!request.arguments.joined().contains(secret))
                #expect(!server.arguments.joined().contains(secret))
                #expect(!String(reflecting: request).contains(secret))
            }
            #expect(request.environment["KOPIA_WEBDAV_PASSWORD"] == nil)
        }
        #expect(server.webDAVConfiguration == payload)
        let document = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        #expect(document["enableActions"] as? Bool == false)
        let cache = try #require(document["caching"] as? [String: Any])
        #expect(cache["maxCacheSize"] as? Int == 5_242_880_000)
    }

    @Test func keychainEnvelopeIsBoundToDestination() async throws {
        let setup = try setup()
        let repository = try repository(kind: setup.kind)
        let secrets = ServiceTestSecrets()
        try await secrets.write(SecretValue(data: JSONEncoder().encode(setup)), for: repository.secretRef)
        let credentials = try await RepositoryCredentials.read(repository: repository, secrets: secrets)
        #expect(credentials.password == setup.backupPassword)
        #expect(credentials.webDAV != nil)
        #expect(credentials.s3 == nil)
        let other = try Repository(
            name: "Other", kind: .webdav(url: #require(URL(string: "https://other.invalid/dav"))),
            identity: repository.identity, secretRef: repository.secretRef)
        await #expect(throws: BackupOperationError.operationFailed) {
            try await RepositoryCredentials.read(repository: other, secrets: secrets)
        }
    }

    @Test func probeTimeoutIsDeniedAndCancellationPropagates() async throws {
        struct Failure: KopiaProcessRunning {
            let cancelled: Bool
            func run(_ request: KopiaProcessRequest) async throws -> KopiaProcessResult {
                if cancelled { throw CancellationError() }
                throw KopiaProcessError.timedOut
            }
        }
        let root = URL(fileURLWithPath: "/tmp/probe-test")
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        let probe = KopiaRepositoryProbe(process: Failure(cancelled: false))
        #expect(
            try await !probe.check(
                executable: root, paths: paths, temporaryDirectory: root,
                user: "test", password: "test-password"))
        await #expect(throws: CancellationError.self) {
            try await KopiaRepositoryProbe(process: Failure(cancelled: true)).check(
                executable: root,
                paths: paths, temporaryDirectory: root, user: "test", password: "test-password")
        }
    }

    private func repository(kind: RepositoryKind) throws -> Repository {
        try Repository(
            name: "WebDAV", kind: kind,
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "host"), secretRef: SecretRef())
    }
    private func setup() throws -> WebDAVSetup {
        try WebDAVSetup(
            url: #require(URL(string: "https://storage.invalid/dav/backups/")),
            username: "username-marker", password: "password-marker", backupPassword: "backup-marker-123")
    }
}
