import BackupDomain
import Darwin
import Foundation

struct LocalConfigFileSystem: ConfigFileSystem {
    private let directory: URL

    init(directory: URL) throws {
        guard directory.isFileURL, directory.query == nil, directory.fragment == nil,
            DomainValidation.absolutePath(directory.path), directory.path != "/"
        else { throw ConfigStoreError.unsafeStorage }
        self.directory = directory
    }

    func withLock<T>(_ operation: (any ConfigFileAccess) throws -> T) throws -> T {
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw ConfigStoreError.storageUnavailable }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ConfigStoreError.unsafeStorage }
        defer { close(directoryFD) }
        var attributes = stat()
        guard fstat(directoryFD, &attributes) == 0, attributes.st_uid == getuid(),
            attributes.st_mode & 0o7777 == 0o700
        else { throw ConfigStoreError.unsafeStorage }
        let lockFD = openat(directoryFD, ".config.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw ConfigStoreError.unsafeStorage }
        defer { close(lockFD) }
        try ConfigDiskAccess.validate(lockFD)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw ConfigStoreError.storageUnavailable }
        defer { _ = flock(lockFD, LOCK_UN) }
        return try operation(ConfigDiskAccess(directoryFD: directoryFD))
    }
}

private struct ConfigDiskAccess: ConfigFileAccess {
    let directoryFD: Int32

    static func validate(_ descriptor: Int32) throws {
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
            attributes.st_mode & S_IFMT == S_IFREG,
            attributes.st_mode & 0o7777 == 0o600,
            attributes.st_uid == getuid(), attributes.st_nlink == 1
        else { throw ConfigStoreError.unsafeStorage }
    }

    func read(_ file: ConfigFile) throws -> Data? {
        let fd = openat(directoryFD, file.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ConfigStoreError.unsafeStorage
        }
        defer { close(fd) }
        try Self.validate(fd)
        var attributes = stat()
        guard fstat(fd, &attributes) == 0 else { throw ConfigStoreError.storageUnavailable }
        guard attributes.st_size <= ConfigCodec.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw ConfigStoreError.storageUnavailable
            }
            if count == 0 { return result }
            guard result.count + count <= ConfigCodec.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    func replace(_ file: ConfigFile, with data: Data) throws {
        guard data.count <= ConfigCodec.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
        // Validate existing targets without following symlinks. Corrupt contents may be explicitly recovered.
        let existing = openat(directoryFD, file.rawValue, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if existing >= 0 {
            defer { close(existing) }
            try Self.validate(existing)
        } else if errno != ENOENT {
            throw ConfigStoreError.unsafeStorage
        }
        let name = ".config-" + UUID().uuidString + ".tmp"
        let fd = openat(directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ConfigStoreError.storageUnavailable }
        defer {
            close(fd)
            _ = unlinkat(directoryFD, name, 0)
        }
        try Self.validate(fd)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                guard let base = bytes.baseAddress else { throw ConfigStoreError.storageUnavailable }
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ConfigStoreError.storageUnavailable }
                offset += count
            }
        }
        try Task.checkCancellation()
        guard fsync(fd) == 0, renameat(directoryFD, name, directoryFD, file.rawValue) == 0,
            fsync(directoryFD) == 0
        else { throw ConfigStoreError.storageUnavailable }
    }
}
