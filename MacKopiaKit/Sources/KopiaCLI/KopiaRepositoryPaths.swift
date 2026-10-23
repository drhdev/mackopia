import Foundation

/// App-owned local state, identified by UUID. Destination/source paths never enter this factory.
struct KopiaRepositoryPaths: Sendable {
    let homeDirectory: URL
    let configurationDirectory: URL
    let cacheDirectory: URL
    let logDirectory: URL

    init(repositoryID: UUID, homeDirectory: URL) throws {
        guard homeDirectory.isFileURL, !homeDirectory.path.utf8.contains(0) else {
            throw KopiaProcessError.invalidRequest
        }
        self.homeDirectory = homeDirectory
        let identifier = repositoryID.uuidString
        configurationDirectory =
            homeDirectory
            .appendingPathComponent("Library/Application Support/MacKopia/Repositories")
            .appendingPathComponent(identifier)
        cacheDirectory = homeDirectory.appendingPathComponent("Library/Caches/MacKopia").appendingPathComponent(
            identifier)
        logDirectory = homeDirectory.appendingPathComponent("Library/Logs/MacKopia/kopia").appendingPathComponent(
            identifier)
    }
}
