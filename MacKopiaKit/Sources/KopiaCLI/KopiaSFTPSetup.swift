import BackupDomain
import Darwin
import Foundation

/// Kopia 0.23.1: create-only never writes a connection; all later operations use fresh anonymous pipes.
package struct KopiaSFTPSetup: Sendable {
    package let executable: URL
    package let home: URL
    package let temporary: URL
    package let user: String

    package init(executable: URL, home: URL, temporary: URL, user: String) {
        self.executable = executable; self.home = home; self.temporary = temporary; self.user = user
    }

    package static func configuration(repository: Repository, home: URL, setup: SFTPSetup) throws -> Data {
        try setup.validate()
        guard repository.kind == setup.kind else { throw KopiaProcessError.invalidRequest }
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        guard setup.passphrase.isEmpty, !setup.privateKey.contains("ENCRYPTED") else {
            throw KopiaProcessError.invalidRequest
        }
        try KopiaSFTPTrust.validate(setup: setup, directory: paths.configurationDirectory)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "storage": [
                    "type": "sftp",
                    "config": [
                        "host": setup.host, "port": setup.port, "username": setup.username, "path": setup.path,
                        "keyData": setup.privateKey, "externalSSH": false,
                        "knownHostsFile": paths.configurationDirectory.appendingPathComponent("known_hosts").path,
                    ],
                ],
                "username": repository.identity.overrideUser, "hostname": repository.identity.overrideHost,
                "description": repository.name, "enableActions": false,
                "caching": [
                    "cacheDirectory": paths.cacheDirectory.path, "maxCacheSize": 5_242_880_000,
                    "maxMetadataCacheSize": 5_242_880_000, "maxListCacheDuration": 30,
                ],
            ], options: [.sortedKeys])
        guard data.count <= 65_536 else { throw KopiaProcessError.invalidRequest }
        return data
    }

    package func perform(repository: Repository, setup: SFTPSetup, create: Bool) async throws {
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory,
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = paths.configurationDirectory
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw KopiaProcessError.invalidRequest }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw KopiaProcessError.invalidRequest
        }
        try KopiaSFTPTrust.install(setup: setup, directory: directory)
        let data = try Self.configuration(repository: repository, home: home, setup: setup)
        let context = KopiaExecutionContext(
            executable: executable, paths: paths,
            temporaryDirectory: temporary, user: user, configuration: .webDAV(data),
            backupPassword: setup.backupPassword)
        if create {
            // Only this create-only bootstrap uses a file path. No connect/config-write fallback is allowed.
            let bootstrap = KopiaExecutionContext(
                executable: executable, paths: paths,
                temporaryDirectory: temporary, user: user, configuration: .file,
                backupPassword: setup.backupPassword
            ).request(for: .repositoryStatus)
            let request = KopiaProcessRequest(
                executable: executable,
                arguments: Array(bootstrap.arguments.dropLast(3)) + [
                    "repository", "create", "sftp", "--create-only", "--host=" + setup.host,
                    "--port=" + String(setup.port), "--username=" + setup.username, "--path=" + setup.path,
                    "--known-hosts=" + directory.appendingPathComponent("known_hosts").path,
                    "--cache-directory=" + paths.cacheDirectory.path, "--no-check-for-updates",
                    "--override-username=" + repository.identity.overrideUser,
                    "--override-hostname=" + repository.identity.overrideHost,
                ],
                environment: bootstrap.environment, timeout: .seconds(60),
                webDAVConfiguration: Data(setup.privateKey.utf8), repositoryDirectory: directory, pipeUse: .sftpKey)
            guard try await KopiaProcess().run(request).exitCode == 0 else {
                throw KopiaProcessError.invalidRequest
            }
        }
        guard
            try await KopiaRepositoryProbe().check(
                executable: executable, paths: paths,
                temporaryDirectory: temporary, user: user, password: setup.backupPassword, webDAV: data)
        else { throw KopiaProcessError.invalidRequest }
        if create {
            _ = try await KopiaCommandRunner(process: KopiaProcess()).run(.initializeBalancedPolicy, context: context)
            _ = try await KopiaCommandRunner(process: KopiaProcess()).run(.claimMaintenanceOwner, context: context)
        } else {
            let info = try await KopiaMaintenanceReader().read(
                executable: executable, paths: paths,
                temporaryDirectory: temporary, user: user, backupPassword: setup.backupPassword,
                lowPriority: true, webDAV: data)
            if try info.fullMaintenance(identity: repository.identity, at: .now) == .ownerRequired {
                _ = try await KopiaCommandRunner(process: KopiaProcess()).run(.claimMaintenanceOwner, context: context)
            }
        }
    }
}
