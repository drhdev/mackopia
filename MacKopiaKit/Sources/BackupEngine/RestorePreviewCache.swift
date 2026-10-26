import BackupDomain
import Darwin
import Foundation

/// Only UUID sessions inside our private cache belong to the preview lifecycle.
enum RestorePreviewCache {
    static func root(home: URL) -> URL {
        home.appendingPathComponent("Library/Caches/MacKopia/QuickLook")
    }

    static func prepare(home: URL) throws -> URL {
        let directory = root(home: home)
        guard home.isFileURL, directory.resolvingSymlinksInPath().path == directory.path else {
            throw LocalServiceIssue.destination
        }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try validate(directory)
        return directory
    }

    static func removeAbandonedSessions(home: URL) throws {
        let directory = root(home: home)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw LocalServiceIssue.destination
        }
        try validate(directory)
        for session in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            // Unrecognized files, permissive directories and symlinks are never ours to remove.
            guard UUID(uuidString: session.lastPathComponent)?.uuidString == session.lastPathComponent,
                lstat(session.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700
            else { continue }
            try FileManager.default.removeItem(at: session)
        }
    }

    private static func validate(_ directory: URL) throws {
        var info = stat()
        guard directory.resolvingSymlinksInPath().path == directory.path,
            lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700
        else { throw LocalServiceIssue.destination }
    }
}
