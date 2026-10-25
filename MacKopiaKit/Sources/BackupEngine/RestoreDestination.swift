import BackupDomain
import Darwin
import Foundation

/// Creates a private conflict-free container. Partial output is retained after failure/cancellation.
struct RestoreDestination {
    static func create(parent: BackupSource, repository: Repository) throws -> URL {
        let url = URL(fileURLWithPath: parent.path)
        guard url.resolvingSymlinksInPath().path == parent.path else { throw LocalServiceIssue.destination }
        if case .filesystem(let repositoryPath, _) = repository.kind, isWithin(parent.path, repositoryPath) {
            throw LocalServiceIssue.destination
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeIsLocalKey])
        guard values.isDirectory == true, values.volumeIsLocal == true else { throw LocalServiceIssue.destination }
        try parent.volume.requireMatch(uuid: values.volumeUUIDString)
        let descriptor = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw LocalServiceIssue.destination }
        defer { close(descriptor) }
        let name = "MacKopia-" + UUID().uuidString
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw LocalServiceIssue.destination }
        let container = url.appendingPathComponent(name, isDirectory: true)
        guard container.resolvingSymlinksInPath().path == container.path else { throw LocalServiceIssue.destination }
        return container.appendingPathComponent("Restore")
    }
    private static func isWithin(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
