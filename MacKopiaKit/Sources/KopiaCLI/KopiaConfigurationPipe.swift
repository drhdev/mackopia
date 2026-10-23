import Darwin
import Foundation

/// Agent-owned, single-process transport. The spawning code must explicitly dup readDescriptor
/// to childDescriptor; CLOEXEC prevents accidental inheritance by unrelated child processes.
/// Never reuse a consumed configuration pipe, or invoke Kopia configuration-writing commands.
final class KopiaConfigurationPipe {
    static let maximumPayloadSize = 65_536
    static let childDescriptor: Int32 = 3

    let configurationURL: URL
    private(set) var readDescriptor: Int32
    private let directory: URL
    private let writer: Task<Void, any Error>
    private var closed = false

    init(payload: Data, repositoryDirectory: URL, clock: any Clock<Duration> = ContinuousClock()) throws {
        guard !payload.isEmpty, payload.count <= Self.maximumPayloadSize else {
            throw KopiaConfigurationError.invalidPayload
        }
        // The caller supplies its isolated, owned repository directory, never a destination root.
        var info = stat()
        let root = repositoryDirectory.path
        guard repositoryDirectory.isFileURL, !root.utf8.contains(0),
            lstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700
        else { throw KopiaConfigurationError.unsafeDirectory }

        let lock = repositoryDirectory.appendingPathComponent("repository.mlock")
        let lockFD = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw KopiaConfigurationError.unsafeDirectory }
        defer { Darwin.close(lockFD) }
        guard fstat(lockFD, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
            info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600, info.st_nlink == 1
        else { throw KopiaConfigurationError.unsafeDirectory }

        var template = Array(repositoryDirectory.appendingPathComponent("runtime-XXXXXX").path.utf8CString)
        guard mkdtemp(&template) != nil else { throw KopiaConfigurationError.transportUnavailable }
        directory = URL(
            fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self),
            isDirectory: true)
        configurationURL = directory.appendingPathComponent("repository.config")
        var descriptors: [Int32] = [-1, -1]
        guard Darwin.pipe(&descriptors) == 0 else {
            Self.removeDirectory(directory)
            throw KopiaConfigurationError.transportUnavailable
        }
        // dup2(fd, fd) does not reliably clear CLOEXEC in Darwin spawn file actions.
        // Keep the parent reader away from the fixed child descriptor, including parallel launches.
        let reader = fcntl(descriptors[0], F_DUPFD_CLOEXEC, 4)
        guard reader >= 0 else {
            for descriptor in descriptors { Darwin.close(descriptor) }
            Self.removeDirectory(directory)
            throw KopiaConfigurationError.transportUnavailable
        }
        Darwin.close(descriptors[0])
        descriptors[0] = reader
        do {
            for descriptor in descriptors {
                guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw KopiaConfigurationError.transportUnavailable
                }
            }
            guard fcntl(descriptors[1], F_SETFL, O_NONBLOCK) == 0,
                fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0
            else { throw KopiaConfigurationError.transportUnavailable }
            guard symlink("/dev/fd/\(Self.childDescriptor)", configurationURL.path) == 0,
                symlink(lock.path, configurationURL.path + ".mlock") == 0,
                chmod(directory.path, 0o500) == 0
            else { throw KopiaConfigurationError.transportUnavailable }
        } catch {
            for descriptor in descriptors { Darwin.close(descriptor) }
            Self.removeDirectory(directory)
            throw error
        }
        readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        writer = Task.detached {
            defer { Darwin.close(writeDescriptor) }
            var offset = 0
            while offset < payload.count {
                try Task.checkCancellation()
                let written = payload.withUnsafeBytes { buffer in
                    Darwin.write(writeDescriptor, buffer.baseAddress?.advanced(by: offset), payload.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    // Nonblocking writes make cancellation independent of pipe capacity or child startup.
                    try await clock.sleep(for: .milliseconds(10))
                } else {
                    throw KopiaConfigurationError.deliveryFailed
                }
            }
        }
    }

    func waitForDelivery() async throws {
        try await writer.value
    }

    /// Once spawn has duplicated the descriptor, the parent must release its reader so an
    /// early child exit produces EPIPE instead of leaving a writer waiting on its own reader.
    func didLaunch() {
        guard readDescriptor >= 0 else { return }
        Darwin.close(readDescriptor)
        readDescriptor = -1
    }

    /// Call after the child has exited/reaped, including failed spawn and cancellation paths.
    func close() {
        guard !closed else { return }
        closed = true
        writer.cancel()
        didLaunch()
        Self.removeDirectory(directory)
    }

    deinit { close() }

    private static func removeDirectory(_ directory: URL) {
        chmod(directory.path, 0o700)
        // Only remove entries we created; never traverse the configuration/lock symlinks.
        unlink(directory.appendingPathComponent("repository.config").path)
        unlink(directory.appendingPathComponent("repository.config.mlock").path)
        rmdir(directory.path)
    }
}
