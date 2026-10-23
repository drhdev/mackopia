import Foundation
import Testing

@testable import KopiaCLI

struct KopiaCommandTests {
    @Test func typedCommandsAlwaysCarryIsolatedPathsAndKeepSecretsOutOfArguments() throws {
        let identifier = UUID()
        let paths = try KopiaRepositoryPaths(
            repositoryID: identifier, homeDirectory: URL(fileURLWithPath: "/fixture/home"))
        let root = paths.configurationDirectory
        let password = UUID().uuidString
        for configuration in [KopiaExecutionContext.Configuration.file, .webDAV(Data("{}".utf8))] {
            let context = KopiaExecutionContext(
                executable: URL(fileURLWithPath: "/fixture/kopia"), paths: paths,
                temporaryDirectory: URL(fileURLWithPath: "/fixture/tmp"),
                user: "test-user", configuration: configuration, backupPassword: password)
            for command in [KopiaCommand.repositoryStatus, .maintenanceInfo] {
                let request = context.request(for: command)
                #expect(request.arguments.contains("--log-dir=" + paths.logDirectory.path))
                #expect(request.arguments.contains("--no-use-keychain"))
                #expect(request.arguments.suffix(3) == command.arguments[...])
                #expect(!request.arguments.joined().contains(password))
                #expect(request.environment["KOPIA_PASSWORD"] == password)
                #expect(request.environment["KOPIA_CACHE_DIRECTORY"] == paths.cacheDirectory.path)
                #expect(!String(reflecting: context).contains(password))
                if request.webDAVConfiguration != nil {
                    #expect(!request.arguments.contains(where: { $0.hasPrefix("--config-file") }))
                    #expect(request.repositoryDirectory == root)
                } else {
                    #expect(
                        request.arguments.contains(
                            "--config-file=" + root.appendingPathComponent("repository.config").path))
                }
            }
        }
    }
    @Test func failedCommandDoesNotPublishChildOutput() async throws {
        struct Failure: KopiaProcessRunning {
            let secret: String
            func run(_ request: KopiaProcessRequest) async throws -> KopiaProcessResult {
                KopiaProcessResult(exitCode: 7, standardOutput: Data(secret.utf8), standardError: Data(secret.utf8))
            }
        }
        let secret = UUID().uuidString
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/fixture/home"))
        let context = KopiaExecutionContext(
            executable: URL(fileURLWithPath: "/fixture/kopia"), paths: paths,
            temporaryDirectory: URL(fileURLWithPath: "/fixture/tmp"), user: "test-user", configuration: .file,
            backupPassword: secret)
        let runner = KopiaCommandRunner(process: Failure(secret: secret))
        let failure = await #expect(throws: KopiaProcessError.commandFailed(exitCode: 7)) {
            try await runner.run(.repositoryStatus, context: context)
        }
        #expect(!String(reflecting: failure).contains(secret))
    }

}
