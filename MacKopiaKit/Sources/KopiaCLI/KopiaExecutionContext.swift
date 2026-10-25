import Foundation

struct KopiaExecutionContext: Sendable, CustomReflectable {
    enum Configuration: Sendable {
        case file
        case webDAV(Data)
    }
    let executable: URL
    let paths: KopiaRepositoryPaths
    let temporaryDirectory: URL
    let user: String
    let configuration: Configuration
    let backupPassword: String
    var s3: KopiaS3Authentication? = nil

    var customMirror: Mirror { Mirror(self, children: ["context": "<private>"]) }

    func request(for command: KopiaCommand) -> KopiaProcessRequest {
        let logs = paths.logDirectory
        let cache = paths.cacheDirectory
        let repositoryDirectory = paths.configurationDirectory
        var arguments = ["--log-dir=" + logs.path, "--no-progress", "--no-use-keychain", "--no-persist-credentials"]
        var payload: Data?
        var runtimeRoot: URL?
        switch configuration {
        case .file:
            arguments.append("--config-file=" + repositoryDirectory.appendingPathComponent("repository.config").path)
        case .webDAV(let data):
            // Kopia 0.23.1: config mutation would reread a consumed pipe and may persist credentials.
            // Only typed operations without config mutation are admitted to this API.
            payload = data
            runtimeRoot = repositoryDirectory
        }
        arguments += command.arguments
        return KopiaProcessRequest(
            executable: executable, arguments: arguments,
            environment: [
                "HOME": paths.homeDirectory.path, "USER": user, "TMPDIR": temporaryDirectory.path,
                "KOPIA_LOG_DIR": logs.path, "KOPIA_CACHE_DIRECTORY": cache.path,
                "KOPIA_PASSWORD": backupPassword,
            ].merging(s3?.environment ?? [:]) { _, new in new },
            webDAVConfiguration: payload, repositoryDirectory: runtimeRoot)
    }
}
