import BackupDomain
import Darwin
import Foundation

/// Only the service may bootstrap an isolated filesystem connection. No arbitrary CLI surface.
package struct KopiaLocalSetup: Sendable {
    package let executable: URL
    package let home: URL
    package let temporary: URL
    package let user: String

    package init(executable: URL, home: URL, temporary: URL, user: String) {
        self.executable = executable; self.home = home; self.temporary = temporary; self.user = user
    }

    package func perform(repository: Repository, password: String, create: Bool) async throws {
        guard case .filesystem(let path, let volume) = repository.kind, let volume else {
            throw KopiaProcessError.invalidRequest
        }
        let destination = URL(fileURLWithPath: path)
        try volume.requireMatch(uuid: destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        // Creating in a nonempty directory could mix unrelated data or an existing repository.
        if create, !(try FileManager.default.contentsOfDirectory(atPath: path)).isEmpty {
            throw KopiaProcessError.invalidRequest
        }
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        guard paths.configurationDirectory.resolvingSymlinksInPath().path == paths.configurationDirectory.path else {
            throw KopiaProcessError.invalidRequest
        }
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        guard paths.configurationDirectory.resolvingSymlinksInPath().path == paths.configurationDirectory.path else {
            throw KopiaProcessError.invalidRequest
        }
        let descriptor = open(paths.configurationDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw KopiaProcessError.invalidRequest
        }
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporary,
            user: user, configuration: .file, backupPassword: password)
        let base = context.request(for: .repositoryStatus)
        let arguments =
            Array(base.arguments.dropLast(3)) + [
                "repository", create ? "create" : "connect", "filesystem", "--path=" + path,
                "--cache-directory=" + paths.cacheDirectory.path,
                "--override-username=" + repository.identity.overrideUser,
                "--override-hostname=" + repository.identity.overrideHost, "--no-check-for-updates",
            ]
        let result = try await KopiaProcess().run(
            KopiaProcessRequest(
                executable: executable, arguments: arguments, environment: base.environment, timeout: .seconds(60)))
        guard result.exitCode == 0 else { throw KopiaProcessError.invalidRequest }
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: home)
    }
}
