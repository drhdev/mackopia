import Foundation

/// Read-only child-process evidence, without opening a repository or emitting file contents.
package struct KopiaProtectedFileProbe: Sendable {
    package let executable: URL
    package let home: URL
    package let temporary: URL

    package init(executable: URL, home: URL, temporary: URL) {
        self.executable = executable; self.home = home; self.temporary = temporary
    }

    package func canReadProtectedFile() async throws -> Bool {
        try Task.checkCancellation()
        let file = home.appendingPathComponent("Library/Safari/Bookmarks.plist")
        guard file.resolvingSymlinksInPath().path == file.path else { return false }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize,
            size > 0, size <= 1_048_576
        else { return false }
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: home)
        // Kopia 0.23.1: readInputFile uses os.Open + io.ReadFull before selecting algorithms.
        // "none" selects no methods: one bounded file read, no compression work or repository.
        // Source: cli/command_benchmark_compression.go at v0.23.1.
        let request = KopiaProcessRequest(
            executable: executable,
            arguments: [
                "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path,
                "--log-dir=" + paths.logDirectory.path, "--no-progress", "--no-use-keychain",
                "--no-persist-credentials",
                "--disable-file-logging", "--disable-content-log", "benchmark", "compression",
                "--data-file=" + file.path, "--algorithms=none", "--repeat=1",
            ],
            environment: [
                "HOME": home.path, "USER": NSUserName(), "TMPDIR": temporary.path,
                "KOPIA_CACHE_DIRECTORY": paths.cacheDirectory.path, "KOPIA_LOG_DIR": paths.logDirectory.path,
            ],
            timeout: .seconds(10), outputLimit: 4096)
        return try await KopiaProcess().run(request).exitCode == 0
    }
}
