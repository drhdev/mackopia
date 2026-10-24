import Foundation

/// Exact-source writes; a successful upload response only acknowledges the request.
package protocol KopiaBackupServing: KopiaPolicyServing {
    func repositoryStatus() async throws -> KopiaRepositoryStatus
    func sources() async throws -> KopiaSources
    func snapshotManifests(source: KopiaSnapshotSource) async throws -> KopiaSnapshots
    func startUpload(source: KopiaSnapshotSource) async throws
    func cancelUpload(source: KopiaSnapshotSource) async throws
}

/// Owned by a protected engine operation. Closing must finish process reaping before returning.
package struct KopiaBackupSession: Sendable {
    package let service: any KopiaBackupServing
    package let close: @Sendable () async throws -> Void

    package init(service: any KopiaBackupServing, close: @escaping @Sendable () async throws -> Void) {
        self.service = service
        self.close = close
    }

    package static func start(
        executable: URL, repositoryID: UUID, homeDirectory: URL, temporaryDirectory: URL,
        user: String, backupPassword: String, lowPriority: Bool = false
    ) async throws -> Self {
        let configuration = try KopiaServerConfiguration(
            executable: executable, repositoryID: repositoryID, homeDirectory: homeDirectory,
            temporaryDirectory: temporaryDirectory, user: user, backupPassword: backupPassword)
        let process = KopiaServerProcess()
        let handshake = try await process.start(configuration: configuration, lowPriority: lowPriority)
        let client = KopiaServerClient(handshake: handshake)
        return Self(service: client) {
            await client.close()
            try await process.stop()
        }
    }
}
