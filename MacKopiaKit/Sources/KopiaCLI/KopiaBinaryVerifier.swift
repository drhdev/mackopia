import BackupDomain
import Foundation

package protocol KopiaBinaryVerifying: Sendable {
    func verify() async throws
}

/// Agent-side version probe. The expected version must come from Config/kopia-version.json.
/// Installation hashes/signatures are a separate boundary; self-reported version is not authentication.
package struct KopiaBinaryVerifier: KopiaBinaryVerifying, CustomReflectable {
    private let executable: URL
    private let paths: KopiaRepositoryPaths
    private let temporaryDirectory: URL
    private let expectedVersion: String
    private let process: any KopiaProcessRunning

    package init(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL, expectedVersion: String
    ) throws {
        try self.init(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            expectedVersion: expectedVersion, process: KopiaProcess())
    }

    init(
        executable: URL, paths: KopiaRepositoryPaths, temporaryDirectory: URL,
        expectedVersion: String, process: any KopiaProcessRunning
    ) throws {
        let components = expectedVersion.split(separator: ".", omittingEmptySubsequences: false)
        guard expectedVersion.utf8.count <= 64, components.count == 3,
            components.allSatisfy({
                !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) })
                    && ($0.count == 1 || $0.first != "0")
            }),
            [executable, paths.homeDirectory, temporaryDirectory].allSatisfy({
                $0.isFileURL && DomainValidation.absolutePath($0.path)
                    && $0.query == nil && $0.fragment == nil
            })
        else { throw KopiaBinaryVerificationError.invalidConfiguration }
        self.executable = executable
        self.paths = paths
        self.temporaryDirectory = temporaryDirectory
        self.expectedVersion = expectedVersion
        self.process = process
    }

    package func verify() async throws {
        try Task.checkCancellation()
        do {
            // Reject a final executable symlink; enclosing bundle trust is established separately.
            var url = executable
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false,
                FileManager.default.isExecutableFile(atPath: url.path)
            else { throw KopiaBinaryVerificationError.unavailable }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw KopiaBinaryVerificationError.unavailable
        }
        try Task.checkCancellation()
        let result: KopiaProcessResult
        do {
            result = try await process.run(
                KopiaProcessRequest(
                    executable: executable,
                    arguments: [
                        "--config-file="
                            + paths.configurationDirectory.appendingPathComponent("repository.config").path,
                        "--log-dir=" + paths.logDirectory.path, "--no-use-keychain", "--version",
                    ],
                    environment: [
                        "HOME": paths.homeDirectory.path, "TMPDIR": temporaryDirectory.path,
                        "KOPIA_LOG_DIR": paths.logDirectory.path,
                        "KOPIA_CACHE_DIRECTORY": paths.cacheDirectory.path,
                    ],
                    timeout: .seconds(10), outputLimit: 4096))
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw KopiaBinaryVerificationError.probeFailed
        }
        guard result.exitCode == 0 else { throw KopiaBinaryVerificationError.probeFailed }
        guard let output = String(data: result.standardOutput, encoding: .utf8), !output.isEmpty,
            output.utf8.count <= 4096
        else { throw KopiaBinaryVerificationError.invalidResponse }
        let line = output.trimmingCharacters(in: .newlines)
        guard !line.isEmpty, line.utf8.allSatisfy({ (32...126).contains($0) }),
            let version = line.split(separator: " ").first
        else { throw KopiaBinaryVerificationError.invalidResponse }
        guard version == expectedVersion else { throw KopiaBinaryVerificationError.versionMismatch }
    }

    package var customMirror: Mirror { Mirror(self, children: ["probe": "<private>"]) }
}
