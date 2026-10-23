import Foundation
import Testing

private struct CancellationSource: Decodable {
    struct Counters: Decodable {
        let cachedBytes: Int64
        let hashedBytes: Int64
        let uploadedBytes: Int64
        let estimatedBytes: Int64
        let hashedFiles: Int
        let errors: Int
        let ignoredErrors: Int
    }

    struct Snapshot: Decodable {
        struct Statistics: Decodable {
            let totalSize: Int64
            let fileCount: Int
            let cachedFiles: Int
            let errorCount: Int
        }

        struct Root: Decodable {
            struct Summary: Decodable {
                let files: Int
                let size: Int64
            }

            let summ: Summary
        }

        let stats: Statistics
        let incomplete: String?
        let rootEntry: Root
    }

    let status: String
    let upload: Counters?
    let lastSnapshot: Snapshot?
}

private struct CancellationSnapshots: Decodable {
    struct Snapshot: Decodable {
        let incomplete: String?
        let rootID: String
    }

    let snapshots: [Snapshot]
}

@Test func recordedCancellationPreservesPartialSnapshot() throws {
    let decoder = JSONDecoder()
    let active = try decoder.decode(CancellationSource.self, from: fixture("cancel-active-source"))
    #expect(active.status == "UPLOADING")
    let progress = try #require(active.upload)
    #expect(progress.hashedFiles >= 16)
    #expect(progress.hashedBytes > 0)
    #expect(progress.cachedBytes >= 0)
    #expect(progress.uploadedBytes >= 0)
    #expect(progress.errors == 0)
    #expect(progress.ignoredErrors == 0)
    let idle = try decoder.decode(CancellationSource.self, from: fixture("cancel-idle-source"))
    #expect(idle.status == "IDLE")
    #expect(idle.upload == nil)
    let snapshots = try decoder.decode(CancellationSnapshots.self, from: fixture("cancel-snapshots"))
    let canceled = try #require(snapshots.snapshots.first { $0.incomplete == "canceled" })
    #expect(!canceled.rootID.isEmpty)
}

@Test func recordedResumeReusesFilesAfterServerRestart() throws {
    let source = try JSONDecoder().decode(CancellationSource.self, from: fixture("resume-idle-source"))
    #expect(source.status == "IDLE")
    let snapshot = try #require(source.lastSnapshot)
    #expect(snapshot.incomplete == nil)
    #expect(snapshot.rootEntry.summ.files == 128)
    #expect(snapshot.rootEntry.summ.size == 256 * 1024 * 1024)
    let stats = snapshot.stats
    #expect(stats.cachedFiles > 0)
    #expect(stats.cachedFiles < 128)
    // Kopia 0.23.1: stats.fileCount counts processed files; cached files are separate.
    #expect(stats.fileCount + stats.cachedFiles == 128)
    #expect(stats.totalSize == 256 * 1024 * 1024)
    #expect(stats.errorCount == 0)
}
