import BackupDomain
import Darwin
import Foundation

package enum ReadAccessObservation: Sendable, Equatable { case readable, denied, missing, unknown }

package protocol ReadAccessProbing: Sendable {
    func readDirectory(at path: String) async throws -> ReadAccessObservation
    func readFile(at path: String) async throws -> ReadAccessObservation
}

/// Actual bounded reads, rather than access(2) or metadata, so TCC participates in the check.
/// No contents, directory entries, paths or underlying errors escape this actor.
package actor LocalReadAccessProbe: ReadAccessProbing {
    package init() {}

    package func readDirectory(at path: String) async throws -> ReadAccessObservation {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { return .unknown }
        guard let directory = opendir(path) else {
            let code = errno
            try Task.checkCancellation()
            return Self.failure(code)
        }
        defer { closedir(directory) }
        errno = 0
        let entry = readdir(directory)
        let code = errno
        try Task.checkCancellation()
        // EOF with no errno is a successful read of an empty directory.
        return entry != nil || code == 0 ? .readable : Self.failure(code)
    }

    package func readFile(at path: String) async throws -> ReadAccessObservation {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { return .unknown }
        // Refuse final symlinks and special files; a substituted FIFO must never hang the agent.
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let code = errno
            try Task.checkCancellation()
            return Self.failure(code)
        }
        defer { close(descriptor) }
        var metadata = stat()
        let result = fstat(descriptor, &metadata)
        try Task.checkCancellation()
        guard result == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else { return .unknown }
        var byte: UInt8 = 0
        let count = read(descriptor, &byte, 1)
        let code = errno
        try Task.checkCancellation()
        return count >= 0 ? .readable : Self.failure(code)
    }

    private static func failure(_ code: Int32) -> ReadAccessObservation {
        switch code {
        case EACCES, EPERM: .denied
        case ENOENT: .missing
        default: .unknown
        }
    }
}
