import Foundation
import KopiaCLI

/// Agent-side inputs only. Callers cannot override transport security or add arbitrary flags.
struct KopiaServerConfiguration: Sendable, CustomReflectable {
    enum Configuration: Sendable, CustomReflectable {
        case file
        case webDAV(Data)

        var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }
    }

    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let webDAVConfiguration: Data?
    let repositoryDirectory: URL?

    var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }

    init(
        executable: URL, repositoryID: UUID, homeDirectory: URL, temporaryDirectory: URL,
        user: String, backupPassword: String, configuration: Configuration = .file
    ) throws {
        guard Self.isLocalPath(executable), Self.isLocalPath(homeDirectory),
            Self.isLocalPath(temporaryDirectory), !user.isEmpty, !user.utf8.contains(0),
            !backupPassword.isEmpty, !backupPassword.utf8.contains(0)
        else { throw KopiaServerProcessError.invalidConfiguration }
        let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: homeDirectory)
        self.executable = executable
        environment = [
            "HOME": homeDirectory.path, "USER": user, "TMPDIR": temporaryDirectory.path,
            "KOPIA_PASSWORD": backupPassword, "KOPIA_CACHE_DIRECTORY": paths.cacheDirectory.path,
            "KOPIA_LOG_DIR": paths.logDirectory.path,
        ]
        var arguments = [
            "--log-dir=" + paths.logDirectory.path, "--no-progress", "--no-use-keychain",
            "--no-persist-credentials",
        ]
        switch configuration {
        case .file:
            arguments.append(
                "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path)
            webDAVConfiguration = nil
            repositoryDirectory = nil
        case .webDAV(let data):
            guard !data.isEmpty, data.count <= 65_536 else { throw KopiaServerProcessError.invalidConfiguration }
            // Kopia 0.23.1: the transport creates a fresh config pipe and supplies --config-file.
            webDAVConfiguration = data
            repositoryDirectory = paths.configurationDirectory
        }
        arguments += [
            "server", "start", "--cache-directory=" + paths.cacheDirectory.path,
            "--address=127.0.0.1:0", "--tls-generate-cert",
            // Kopia 0.23.1: macOS SSL policy rejects the default 3650-day certificate.
            "--tls-generate-cert-valid-days=365", "--tls-generate-rsa-key-size=2048",
            "--tls-print-server-cert", "--random-password", "--random-server-control-password",
            "--server-username=mackopia", "--shutdown-on-stdin", "--ui", "--no-grpc", "--control-api",
            "--no-check-for-updates", "--no-async-repo-connect",
        ]
        self.arguments = arguments
    }

    private static func isLocalPath(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "localhost")
            && url.query == nil && url.fragment == nil && !url.path.utf8.contains(0)
            && url.path.hasPrefix("/") && url.standardizedFileURL.path == url.path
    }
}
