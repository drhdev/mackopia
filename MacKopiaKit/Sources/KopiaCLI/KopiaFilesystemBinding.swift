import BackupDomain
import Darwin
import Foundation

/// Validate the isolated connection before starting a server that could run repository policies/actions.
package enum KopiaFilesystemBinding {
    package static func validate(repository: Repository, homeDirectory: URL) throws {
        try repository.kind.validate()
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: homeDirectory)
        let file = paths.configurationDirectory.appendingPathComponent("repository.config")
        guard file.resolvingSymlinksInPath().path == file.path else { throw KopiaProcessError.invalidRequest }
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw KopiaProcessError.invalidRequest }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
            info.st_nlink == 1, info.st_mode & 0o7777 == 0o600, info.st_size <= 1_048_576
        else { throw KopiaProcessError.invalidRequest }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= 1_048_576 else { throw KopiaProcessError.invalidRequest }
            data.append(contentsOf: buffer.prefix(count))
        }
        struct Configuration: Decodable {
            struct Storage: Decodable {
                let type: String
                let config: [String: KopiaStorageValue]
                private enum CodingKeys: String, CodingKey { case type, config }
                private struct Filesystem: Decodable { let path: String }
                init(from decoder: any Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    type = try values.decode(String.self, forKey: .type)
                    if type == "filesystem" {
                        // Kopia 0.23.1 also stores numeric file/dir modes and nullable dirShards.
                        // Preserve the filesystem binding's existing path-only decoding contract.
                        let filesystem = try values.decode(Filesystem.self, forKey: .config)
                        config = ["path": .string(filesystem.path)]
                    } else {
                        config = try values.decode([String: KopiaStorageValue].self, forKey: .config)
                    }
                }
            }
            let storage: Storage
            let username: String
            let hostname: String
            let enableActions: Bool?
        }
        guard let value = try? JSONDecoder().decode(Configuration.self, from: data),
            Self.matches(repository: repository, type: value.storage.type, config: value.storage.config),
            value.username == repository.identity.overrideUser, value.hostname == repository.identity.overrideHost,
            value.enableActions != true
        else { throw KopiaProcessError.invalidRequest }
        // The protected repository reservation excludes other MacKopia writers, not hostile same-UID edits.
    }

    private static func matches(repository: Repository, type: String, config: [String: KopiaStorageValue]) -> Bool {
        switch repository.kind {
        case .filesystem(let path, _): return type == "filesystem" && config["path"] == .string(path)
        case .s3: return type == "s3" && (try? KopiaS3Setup.storage(repository: repository)) == config
        default: return false
        }
    }
}
