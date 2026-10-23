import BackupDomain
import Darwin
import Foundation

struct LocalVolumeMount {
    let device: String
    let path: String

    init(directory: URL) throws {
        var info = statfs()
        let status = directory.withUnsafeFileSystemRepresentation { pointer in
            pointer.map { statfs($0, &info) } ?? -1
        }
        guard status == 0, info.f_flags & UInt32(MNT_LOCAL) != 0 else { throw VolumeProtectionError.unavailable }
        let devicePath = withUnsafeBytes(of: info.f_mntfromname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        let mountPath = withUnsafeBytes(of: info.f_mntonname) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard devicePath.hasPrefix("/dev/disk"), devicePath.utf8.count < 128,
            devicePath.dropFirst(5).utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }),
            DomainValidation.absolutePath(mountPath)
        else { throw VolumeProtectionError.unavailable }
        device = String(devicePath.dropFirst(5))
        path = mountPath
    }
}
