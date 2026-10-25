import BackupDomain
import Darwin
import Foundation

/// Kopia 0.23.1 create-only avoids serializing AWS credentials. Connect writes our own secret-free binding.
package struct KopiaS3Setup: Sendable {
    package let executable: URL
    package let home: URL
    package let temporary: URL
    package let user: String

    package init(executable: URL, home: URL, temporary: URL, user: String) {
        self.executable = executable; self.home = home; self.temporary = temporary; self.user = user
    }

    package func perform(
        repository: Repository, password: String, authentication: KopiaS3Authentication,
        create: Bool
    ) async throws {
        let storage = try Self.storage(repository: repository)
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        let directory = paths.configurationDirectory
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw KopiaProcessError.invalidRequest }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw KopiaProcessError.invalidRequest
        }
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporary,
            user: user, configuration: .file, backupPassword: password, s3: authentication)
        if create {
            guard case .s3(let endpoint, let bucket, let prefix, let region, _) = repository.kind,
                let url = URLComponents(string: endpoint), let host = url.host
            else { throw KopiaProcessError.invalidRequest }
            let base = context.request(for: .repositoryStatus)
            var arguments =
                Array(base.arguments.dropLast(3)) + [
                    "repository", "create", "s3", "--create-only", "--bucket=" + bucket,
                    "--endpoint=" + host + (url.port.map { ":\($0)" } ?? ""), "--prefix=" + prefix,
                    "--region=" + (region ?? "us-east-1"), "--no-check-for-updates",
                ]
            if url.scheme == "http" { arguments.append("--disable-tls") }
            let result = try await KopiaProcess().run(
                KopiaProcessRequest(
                    executable: executable, arguments: arguments, environment: base.environment, timeout: .seconds(60)))
            guard result.exitCode == 0 else { throw S3SetupFailure.create }
        }
        let configuration: [String: Any] = [
            "storage": ["type": "s3", "config": try JSONSerialization.jsonObject(with: JSONEncoder().encode(storage))],
            "username": repository.identity.overrideUser, "hostname": repository.identity.overrideHost,
            "description": repository.name, "enableActions": false,
            "caching": [
                "cacheDirectory": paths.cacheDirectory.path, "maxCacheSize": 5_242_880_000,
                "maxMetadataCacheSize": 5_242_880_000, "maxListCacheDuration": 30,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let file = "repository.config"
        let staging = ".connection-" + UUID().uuidString
        let output = openat(descriptor, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { unlinkat(descriptor, staging, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: true)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        guard renameatx_np(descriptor, staging, descriptor, file, UInt32(RENAME_EXCL)) == 0, fsync(descriptor) == 0
        else {
            throw KopiaProcessError.invalidRequest
        }
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: home)
        let status = try await KopiaProcess().run(context.request(for: .repositoryStatus))
        guard status.exitCode == 0 else { throw S3SetupFailure.status }
        if create {
            // create-only skips populateRepository: initialize the same balanced defaults explicitly.
            let base = context.request(for: .repositoryStatus)
            for command in [
                [
                    "policy", "set", "--global", "--keep-latest=10", "--keep-hourly=48", "--keep-daily=14",
                    "--keep-weekly=8", "--keep-monthly=24", "--keep-annual=3", "--compression=zstd",
                ],
                ["maintenance", "set", "--owner=me"],
            ] {
                let result = try await KopiaProcess().run(
                    KopiaProcessRequest(
                        executable: executable, arguments: Array(base.arguments.dropLast(3)) + command,
                        environment: base.environment))
                guard result.exitCode == 0 else { throw S3SetupFailure.policy }
            }
        } else {
            let info = try await KopiaMaintenanceReader().read(
                executable: executable, paths: paths, temporaryDirectory: temporary, user: user,
                backupPassword: password, lowPriority: true, s3: authentication)
            if try info.fullMaintenance(identity: repository.identity, at: .now) == .ownerRequired {
                let base = context.request(for: .repositoryStatus)
                let result = try await KopiaProcess().run(
                    KopiaProcessRequest(
                        executable: executable,
                        arguments: Array(base.arguments.dropLast(3)) + ["maintenance", "set", "--owner=me"],
                        environment: base.environment))
                guard result.exitCode == 0 else { throw S3SetupFailure.policy }
            }
            // A foreign owner is retained. The shared coordinator will never force their maintenance.
        }
    }

    package static func storage(repository: Repository) throws -> [String: KopiaStorageValue] {
        guard case .s3(let endpoint, let bucket, let prefix, let region, let objectLock) = repository.kind,
            !objectLock, let url = URLComponents(string: endpoint), let host = url.host,
            url.scheme == "https" || (url.scheme == "http" && host == "127.0.0.1"),
            url.path.isEmpty || url.path == "/"
        else { throw KopiaProcessError.invalidRequest }
        try repository.kind.validate()
        return [
            "bucket": .string(bucket), "prefix": .string(prefix),
            "endpoint": .string(host + (url.port.map { ":\($0)" } ?? "")),
            "region": .string(region ?? "us-east-1"), "doNotUseTLS": .bool(url.scheme == "http"),
        ]
    }
}

private enum S3SetupFailure: Error { case create, status, policy }
