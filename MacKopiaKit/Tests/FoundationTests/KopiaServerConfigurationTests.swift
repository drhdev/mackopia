import Foundation
import Testing

@testable import KopiaCLI
@testable import KopiaServer

struct KopiaServerConfigurationTests {
    @Test func fixesSecurityOptionsAndIsolatesRepositoryState() throws {
        let identifier = UUID()
        let password = UUID().uuidString
        let configuration = try makeConfiguration(repositoryID: identifier, password: password)
        let paths = try KopiaRepositoryPaths(repositoryID: identifier, homeDirectory: home)
        let arguments = configuration.arguments
        #expect(arguments.contains("--address=127.0.0.1:0"))
        #expect(arguments.contains("--tls-generate-cert-valid-days=365"))
        #expect(arguments.contains("--random-password"))
        #expect(arguments.contains("--random-server-control-password"))
        #expect(arguments.contains("--tls-print-server-cert"))
        #expect(arguments.contains("--shutdown-on-stdin"))
        #expect(arguments.contains("--no-grpc"))
        #expect(arguments.contains("--no-async-repo-connect"))
        #expect(arguments.contains("--no-persist-credentials"))
        #expect(arguments.contains("--no-use-keychain"))
        #expect(arguments.contains("--ui"))
        #expect(arguments.contains("--control-api"))
        #expect(
            arguments.contains(
                "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path))
        #expect(arguments.contains("--log-dir=" + paths.logDirectory.path))
        #expect(arguments.contains("--cache-directory=" + paths.cacheDirectory.path))
        #expect(configuration.environment["KOPIA_PASSWORD"] == password)
        #expect(configuration.environment["KOPIA_CACHE_DIRECTORY"] == paths.cacheDirectory.path)
        #expect(!arguments.joined().contains(password))
        #expect(!String(reflecting: configuration).contains(password))
        #expect(configuration.webDAVConfiguration == nil)
        #expect(configuration.repositoryDirectory == nil)
        let other = try makeConfiguration()
        #expect(other.environment["KOPIA_CACHE_DIRECTORY"] != configuration.environment["KOPIA_CACHE_DIRECTORY"])
    }

    @Test func webDAVOnlySuppliesInMemoryPayloadToFreshPipeTransport() throws {
        let identifier = UUID()
        let secret = UUID().uuidString
        let payload = Data("{\"password\":\"\(secret)\"}".utf8)
        let input = KopiaServerConfiguration.Configuration.webDAV(payload)
        let configuration = try makeConfiguration(repositoryID: identifier, configuration: input)
        #expect(configuration.webDAVConfiguration == payload)
        let paths = try KopiaRepositoryPaths(repositoryID: identifier, homeDirectory: home)
        #expect(configuration.repositoryDirectory == paths.configurationDirectory)
        #expect(!configuration.arguments.contains(where: { $0.hasPrefix("--config-file") }))
        #expect(!configuration.arguments.joined().contains(secret))
        #expect(!configuration.environment.values.contains(where: { $0.contains(secret) }))
        #expect(!String(reflecting: input).contains(secret))
        #expect(!String(reflecting: configuration).contains(secret))
    }

    @Test func rejectsInvalidInputsBeforeStartingChild() throws {
        for url in [
            try #require(URL(string: "https://example.invalid/kopia")),
            URL(fileURLWithPath: "/fixture/../other"),
            try #require(URL(string: "file://remote/fixture")),
            try #require(URL(string: "file:///fixture?query=1")),
        ] {
            #expect(throws: KopiaServerProcessError.invalidConfiguration) {
                try KopiaServerConfiguration(
                    executable: url, repositoryID: UUID(), homeDirectory: home,
                    temporaryDirectory: home, user: "fixture", backupPassword: "fixture")
            }
        }
        for password in ["", "invalid\0value"] {
            #expect(throws: KopiaServerProcessError.invalidConfiguration) {
                try makeConfiguration(password: password)
            }
        }
        for payload in [Data(), Data(repeating: 0, count: 65_537)] {
            #expect(throws: KopiaServerProcessError.invalidConfiguration) {
                try makeConfiguration(configuration: .webDAV(payload))
            }
        }
    }

    private var home: URL { URL(fileURLWithPath: "/fixture/home") }

    private func makeConfiguration(
        repositoryID: UUID = UUID(), password: String = "fixture",
        configuration: KopiaServerConfiguration.Configuration = .file
    ) throws -> KopiaServerConfiguration {
        try KopiaServerConfiguration(
            executable: URL(fileURLWithPath: "/fixture/kopia"), repositoryID: repositoryID,
            homeDirectory: home, temporaryDirectory: home, user: "fixture", backupPassword: password,
            configuration: configuration)
    }
}
