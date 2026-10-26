import BackupDomain
import Darwin
import Foundation

/// The public trust record is bound to the confirmed fingerprint on every operation.
package enum KopiaSFTPTrust {
    private static func record(_ setup: SFTPSetup) -> Data {
        let host = setup.port == 22 ? setup.host : "[\(setup.host)]:\(setup.port)"
        return Data("\(host) \(setup.hostKey)\n".utf8)
    }

    package static func install(setup: SFTPSetup, directory: URL) throws {
        try setup.validate()
        let path = directory.appendingPathComponent("known_hosts").path
        guard directory.resolvingSymlinksInPath().path == directory.path else { throw KopiaProcessError.invalidRequest }
        let staging = directory.appendingPathComponent(".trust-" + UUID().uuidString).path
        let fd = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { unlink(staging) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: record(setup)); try handle.synchronize(); try handle.close()
        if renameatx_np(AT_FDCWD, staging, AT_FDCWD, path, UInt32(RENAME_EXCL)) != 0 {
            guard errno == EEXIST else { throw KopiaProcessError.invalidRequest }
        }
        try validate(setup: setup, directory: directory)
    }

    package static func validate(setup: SFTPSetup, directory: URL) throws {
        let file = directory.appendingPathComponent("known_hosts")
        guard file.resolvingSymlinksInPath().path == file.path else { throw KopiaProcessError.invalidRequest }
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw KopiaProcessError.invalidRequest }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let expected = record(setup)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o7777 == 0o600,
            info.st_size == expected.count,
            try handle.read(upToCount: expected.count + 1) == expected
        else { throw KopiaProcessError.invalidRequest }
    }
}

extension KopiaSFTPSetup {
    /// Kopia 0.23.1 does not decrypt private keys. OpenSSL receives PEM and passphrase only in memory.
    package static func normalize(_ setup: SFTPSetup, home: URL, temporary: URL) async throws -> SFTPSetup {
        try setup.validate()
        if setup.passphrase.isEmpty {
            guard !setup.privateKey.contains("ENCRYPTED") else { throw KopiaProcessError.invalidRequest }
            return setup
        }
        // Only the proven RSA PEM contract is admitted; encrypted OpenSSH requires a separate parser contract.
        guard
            setup.privateKey.hasPrefix("-----BEGIN RSA PRIVATE KEY-----")
                || setup.privateKey.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----")
        else {
            throw KopiaProcessError.invalidRequest
        }
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: home)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: paths.configurationDirectory) }
        let result = try await KopiaProcess().run(
            KopiaProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/openssl"),
                arguments: ["rsa", "-passin", "env:MACKOPIA_KEY_PASSPHRASE"],
                environment: [
                    "HOME": home.path, "USER": NSUserName(), "TMPDIR": temporary.path,
                    "KOPIA_LOG_DIR": paths.logDirectory.path, "KOPIA_CACHE_DIRECTORY": paths.cacheDirectory.path,
                    "MACKOPIA_KEY_PASSPHRASE": setup.passphrase,
                ], timeout: .seconds(15), outputLimit: 65_536,
                webDAVConfiguration: Data(setup.privateKey.utf8), repositoryDirectory: paths.configurationDirectory,
                pipeUse: .opensslInput))
        guard result.exitCode == 0, let key = String(data: result.standardOutput, encoding: .utf8),
            key.hasPrefix("-----BEGIN RSA PRIVATE KEY-----"), !key.contains("ENCRYPTED")
        else {
            throw KopiaProcessError.invalidRequest
        }
        return try SFTPSetup(
            host: setup.host, port: setup.port, username: setup.username, path: setup.path,
            hostKey: setup.hostKey, hostKeyConfirmed: setup.hostKeyConfirmed,
            privateKey: key, backupPassword: setup.backupPassword, keyRef: setup.keyRef)
    }
}
