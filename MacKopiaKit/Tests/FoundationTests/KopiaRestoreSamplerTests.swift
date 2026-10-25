import Foundation
import Testing

@testable import KopiaCLI

struct KopiaRestoreSamplerTests {
    private let id = String(repeating: "a", count: 32)

    @Test func traversesDirectoriesAndKeepsOnlySmallRegularFiles() async throws {
        let directory = """
            {"stream":"kopia:directory","entries":[
              {"name":"folder","type":"d","obj":"k\(id)","mtime":"2026-10-25T10:00:00Z"},
              {"name":"empty","type":"f","obj":"\(id)","mtime":"2026-10-25T10:00:00Z"},
              {"name":"file","type":"f","size":42,"obj":"\(id)","mtime":"2026-10-25T10:00:00.123456789Z"},
              {"name":"big","type":"f","size":50000000,"obj":"\(id)","mtime":"2026-10-25T10:00:00Z"},
              {"name":"link","type":"s"}
            ]}
            """
        let process = VerifyProcessFixture(output: directory)
        let samples = try await sample(process)
        // The repeated directory object is visited once, preventing cycles.
        #expect(await process.requests.count == 1)
        #expect(samples.map(\.components) == [["empty"], ["file"]])
        #expect(samples.map(\.size) == [0, 42])
        let date = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-25T10:00:00.123456789Z")
        #expect(samples.last?.modifiedAt == date)
        #expect(!String(reflecting: samples).contains("folder"))
    }

    @Test func rejectsTraversalMalformedObjectsAndFailedCommands() async throws {
        for name in ["..", ".", "a/b", "", String(repeating: "x", count: 256)] {
            let process = VerifyProcessFixture(
                output: """
                    {"stream":"kopia:directory","entries":[
                        {"name":"\(name)","type":"f","obj":"\(id)","mtime":"2026-10-25T10:00:00Z"}]}
                    """)
            await #expect(throws: (any Error).self) { try await sample(process) }
        }
        for output in ["{}", "private marker", #"{"stream":"unexpected","entries":[]}"#] {
            await #expect(throws: (any Error).self) { try await sample(VerifyProcessFixture(output: output)) }
        }
        await #expect(throws: (any Error).self) { try await sample(VerifyProcessFixture(code: 1)) }
        for value in ["--all", "../file", "", "kk" + id, "I" + "k" + id] {
            #expect(!KopiaRestoreSampler.validObjectID(value))
        }
    }

    @Test func emptyDirectoryIsInconclusive() async throws {
        for output in [#"{"stream":"kopia:directory"}"#, #"{"stream":"kopia:directory","entries":null}"#] {
            #expect(try await sample(VerifyProcessFixture(output: output)).isEmpty)
        }
    }

    @Test func restoreUsesExactObjectPrivateEnvironmentAndSafeOverwriteFlags() async throws {
        let process = VerifyProcessFixture(output: "")
        let sample = KopiaRestoreSample(components: ["private-name"], objectID: id, size: 3, modifiedAt: .now)
        try await KopiaRestoreSampler(process: process).restore(
            sample, to: URL(fileURLWithPath: "/private/tmp/private-restore/sample"),
            executable: URL(fileURLWithPath: "/tmp/test-kopia"),
            paths: KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/tmp/test-home")),
            temporaryDirectory: URL(fileURLWithPath: "/tmp"), user: "test-user",
            backupPassword: "private-test-marker", lowPriority: true)
        let request = try #require(await process.requests.first)
        #expect(
            request.arguments.suffix(11) == [
                "snapshot", "restore", id, "/private/tmp/private-restore/sample",
                "--no-overwrite-files", "--no-overwrite-directories", "--no-overwrite-symlinks",
                "--write-files-atomically", "--skip-permissions", "--skip-owners", "--skip-times",
            ])
        #expect(!request.arguments.contains { $0.contains("private-name") || $0.contains("private-test-marker") })
        #expect(request.environment["KOPIA_PASSWORD"] == "private-test-marker")
        #expect(request.environment["KOPIA_CACHE_DIRECTORY"] != nil)
        #expect(request.arguments.contains { $0.hasPrefix("--config-file=") })
        #expect(request.arguments.contains { $0.hasPrefix("--log-dir=") })
        #expect(request.lowPriority && request.timeout == .seconds(600))
    }

    private func sample(_ process: VerifyProcessFixture) async throws -> [KopiaRestoreSample] {
        try await KopiaRestoreSampler(process: process).samples(
            rootID: "k" + id, executable: URL(fileURLWithPath: "/tmp/test-kopia"),
            paths: KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/tmp/test-home")),
            temporaryDirectory: URL(fileURLWithPath: "/tmp"), user: "test-user",
            backupPassword: "private-test-marker", lowPriority: true)
    }
}
