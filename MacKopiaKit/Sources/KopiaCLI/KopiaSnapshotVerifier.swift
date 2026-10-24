import Foundation

/// Finite, read-only CLI execution. The owner holds the shared repository reservation throughout.
package struct KopiaSnapshotVerifier: Sendable {
    private let process: any KopiaProcessRunning

    package init() { process = KopiaProcess() }
    init(process: any KopiaProcessRunning) { self.process = process }

    package func verify(
        _ verification: KopiaSnapshotVerification, executable: URL, paths: KopiaRepositoryPaths,
        temporaryDirectory: URL, user: String, backupPassword: String, lowPriority: Bool
    ) async throws {
        let context = KopiaExecutionContext(
            executable: executable, paths: paths, temporaryDirectory: temporaryDirectory,
            user: user, configuration: .file, backupPassword: backupPassword)
        // Bound argv size without truncating large plans. All batches must succeed.
        for offset in stride(from: 0, to: verification.snapshotIDs.count, by: 128) {
            try Task.checkCancellation()
            let ids = Array(verification.snapshotIDs[offset..<min(offset + 128, verification.snapshotIDs.count)])
            var request = context.request(
                for: .snapshotVerify(snapshotIDs: ids, filesPercent: verification.filesPercent))
            request.lowPriority = lowPriority
            request.timeout = .seconds(6 * 60 * 60)
            let result = try await process.run(request)
            guard result.exitCode == 0 else { throw KopiaProcessError.commandFailed(exitCode: result.exitCode) }
            let response = try JSONDecoder().decode(Response.self, from: result.standardOutput)
            // Kopia 0.23.1: verify --json returns aggregate stats/errorCount, not a manifest.
            // Positive work prevents an empty/no-op response from becoming durable trust evidence.
            guard response.errorCount == 0, response.stats.processedObjectCount > 0 else {
                throw KopiaProcessError.invalidRequest
            }
        }
        try Task.checkCancellation()
    }

    struct Response: Decodable {
        struct Stats: Decodable { let processedObjectCount: Int64 }
        let stats: Stats
        let errorCount: Int64
    }
}
