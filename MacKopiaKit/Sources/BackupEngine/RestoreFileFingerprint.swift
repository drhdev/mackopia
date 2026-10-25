import CryptoKit
import Darwin
import Foundation

/// Walk with directory descriptors: neither an entry nor one of its ancestors may be a symlink.
struct RestoreFileFingerprint: Equatable, Sendable {
    let digest: Data
    let size: Int64
    let modifiedAt: Date
    private let device: dev_t
    private let inode: ino_t
    private let modifiedSeconds: Int
    private let modifiedNanoseconds: Int
    private let changedSeconds: Int
    private let changedNanoseconds: Int

    /// Resolve only the authorized root. Entry components below it are always opened without following links.
    static func rootComponents(path: String) -> [String]? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved).split(separator: "/").map(String.init)
    }

    static func read(components: [String]) throws -> Self? {
        guard !components.isEmpty,
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") })
        else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        for (index, component) in components.enumerated() {
            try Task.checkCancellation()
            let flags =
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                | (index == components.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else { return nil }
            close(descriptor)
            descriptor = next
        }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, before.st_size < 50_000_000
        else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; return nil }
            if count == 0 { break }
            total += Int64(count)
            guard total <= before.st_size else { return nil }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard total == before.st_size, fstat(descriptor, &after) == 0,
            before.st_dev == after.st_dev, before.st_ino == after.st_ino,
            before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { return nil }
        return Self(
            digest: Data(hasher.finalize()), size: before.st_size,
            modifiedAt: Date(
                timeIntervalSince1970: Double(before.st_mtimespec.tv_sec)
                    + Double(before.st_mtimespec.tv_nsec) / 1e9),
            device: before.st_dev, inode: before.st_ino,
            modifiedSeconds: before.st_mtimespec.tv_sec, modifiedNanoseconds: before.st_mtimespec.tv_nsec,
            changedSeconds: before.st_ctimespec.tv_sec, changedNanoseconds: before.st_ctimespec.tv_nsec)
    }
}
