import Foundation
import Testing

@testable import KopiaCLI

struct KopiaBinaryVerifierTests {
    @Test func probeHasBoundedIsolatedArgumentsAndNoCredentials() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try binary(in: root)
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        let process = BinaryProbeProcess(output: Data("0.23.1 build: test\n".utf8))
        let verifier = try KopiaBinaryVerifier(
            executable: executable, paths: paths, temporaryDirectory: root,
            expectedVersion: "0.23.1", process: process)
        try await verifier.verify()
        let requests = await process.requests
        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.executable == executable)
        #expect(
            request.arguments == [
                "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path,
                "--log-dir=" + paths.logDirectory.path, "--no-use-keychain", "--version",
            ])
        #expect(
            request.environment == [
                "HOME": root.path, "TMPDIR": root.path, "KOPIA_LOG_DIR": paths.logDirectory.path,
                "KOPIA_CACHE_DIRECTORY": paths.cacheDirectory.path,
            ])
        #expect(request.timeout == .seconds(10))
        #expect(request.outputLimit == 4096)
        #expect(request.webDAVConfiguration == nil && request.repositoryDirectory == nil)
        #expect(!String(reflecting: verifier).contains(root.path))
    }

    @Test func invalidConfigurationIsRejectedBeforeProbing() throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try binary(in: root)
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        for version in ["", "0.23", "0.23.1.2", "0.23.1\0", "0.23.1\n", "00.23.1", "0.023.1", "0.x.1", "-1.0.0"] {
            #expect(throws: KopiaBinaryVerificationError.invalidConfiguration) {
                try KopiaBinaryVerifier(
                    executable: executable, paths: paths, temporaryDirectory: root, expectedVersion: version)
            }
        }
        let remoteURL = try #require(URL(string: "https://example.invalid/kopia"))
        #expect(throws: KopiaBinaryVerificationError.invalidConfiguration) {
            try KopiaBinaryVerifier(
                executable: remoteURL, paths: paths,
                temporaryDirectory: root, expectedVersion: "0.23.1")
        }
    }

    @Test func missingUnexecutableDirectoryAndSymlinkNeverLaunch() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try binary(in: root)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: executable)
        let process = BinaryProbeProcess(output: Data("0.23.1\n".utf8))
        for path in [root.appendingPathComponent("missing"), root, link] {
            let verifier = try probe(path, root: root, process: process)
            await #expect(throws: KopiaBinaryVerificationError.unavailable) { try await verifier.verify() }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        let verifier = try probe(executable, root: root, process: process)
        await #expect(throws: KopiaBinaryVerificationError.unavailable) { try await verifier.verify() }
        #expect(await process.requests.isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try await verifier.verify()
        try FileManager.default.removeItem(at: executable)
        await #expect(throws: KopiaBinaryVerificationError.unavailable) { try await verifier.verify() }
        #expect(await process.requests.count == 1)
    }

    @Test func invalidResponsesAndFailuresNeverExposeOutput() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try binary(in: root)
        for output in [
            Data(), Data([0xff]), Data("0.23.1\0secret".utf8), Data("0.23.1\nsecret".utf8),
            Data(repeating: 65, count: 4097),
        ] {
            let verifier = try probe(executable, root: root, process: BinaryProbeProcess(output: output))
            await #expect(throws: KopiaBinaryVerificationError.invalidResponse) { try await verifier.verify() }
        }
        for output in ["0.23.10\n", "0.23.1-extra\n", "different secret\n"] {
            let verifier = try probe(executable, root: root, process: BinaryProbeProcess(output: Data(output.utf8)))
            await #expect(throws: KopiaBinaryVerificationError.versionMismatch) { try await verifier.verify() }
        }
        for process in [
            BinaryProbeProcess(output: Data("0.23.1\n".utf8), exitCode: 1),
            BinaryProbeProcess(output: Data(), error: KopiaProcessError.timedOut),
            BinaryProbeProcess(output: Data(), error: KopiaProcessError.outputLimitExceeded),
            BinaryProbeProcess(output: Data(), error: NSError(domain: "private-marker", code: 1)),
        ] {
            let verifier = try probe(executable, root: root, process: process)
            await #expect(throws: KopiaBinaryVerificationError.probeFailed) { try await verifier.verify() }
        }
    }

    @Test func cancellationBeforeDuringAndAfterProbeRemainsCancellation() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try binary(in: root)
        for process in [
            BinaryProbeProcess(output: Data(), error: CancellationError()),
            BinaryProbeProcess(output: Data("0.23.1\n".utf8), cancel: true),
            BinaryProbeProcess(output: Data(), error: KopiaProcessError.ioFailed, cancel: true),
        ] {
            let verifier = try probe(executable, root: root, process: process)
            let task = Task<Void, Never> {
                await #expect(throws: CancellationError.self) { try await verifier.verify() }
            }
            await task.value
        }
        let process = BinaryProbeProcess(output: Data())
        let verifier = try probe(executable, root: root, process: process)
        let task = Task<Void, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await verifier.verify() }
        }
        await task.value
        #expect(await process.requests.isEmpty)
    }

    private func binary(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("kopia")
        try Data([0]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func probe(_ executable: URL, root: URL, process: any KopiaProcessRunning) throws -> KopiaBinaryVerifier {
        try KopiaBinaryVerifier(
            executable: executable, paths: KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root),
            temporaryDirectory: root, expectedVersion: "0.23.1", process: process)
    }
}

private actor BinaryProbeProcess: KopiaProcessRunning {
    let output: Data
    let exitCode: Int32
    let error: (any Error)?
    let cancel: Bool
    private(set) var requests: [KopiaProcessRequest] = []

    init(output: Data, exitCode: Int32 = 0, error: (any Error)? = nil, cancel: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.error = error
        self.cancel = cancel
    }

    func run(_ request: KopiaProcessRequest) async throws -> KopiaProcessResult {
        requests.append(request)
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        if let error { throw error }
        return KopiaProcessResult(
            exitCode: exitCode, standardOutput: output, standardError: Data("private-marker".utf8))
    }
}
