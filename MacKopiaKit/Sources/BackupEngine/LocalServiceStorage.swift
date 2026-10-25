import BackupDomain
import Darwin
import Foundation

/// Bootstrap only the service directory; ConfigStore/HistoryStore retain their descriptor-bound checks.
enum LocalServiceStorage {
    static func prepare(home: URL) throws -> URL {
        let directory = home.appendingPathComponent("Library/Application Support/MacKopia")
        guard home.isFileURL, directory.resolvingSymlinksInPath().path == directory.path else {
            throw LocalServiceIssue.destination
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalServiceIssue.destination }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700,
            directory.resolvingSymlinksInPath().path == directory.path
        else { throw LocalServiceIssue.destination }
        return directory
    }
}
