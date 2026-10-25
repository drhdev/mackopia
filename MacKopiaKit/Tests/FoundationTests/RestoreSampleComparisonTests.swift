import Foundation
import Testing

@testable import BackupEngine
@testable import KopiaCLI

struct RestoreSampleComparisonTests {
    @Test func matchingHashSucceedsAndUsesPrivateCleanedDirectory() async throws {
        let fixture = try RestoreComparisonFixture()
        defer { fixture.remove() }
        let result = try await fixture.compare { destination in
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destination.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(destination.lastPathComponent == "sample")
            try fixture.content.write(to: destination)
        }
        #expect(result == true)
        try fixture.expectClean()
    }

    @Test func mismatchMissingOutputAndSymlinkOutputFailAndCleanUp() async throws {
        for mode in ["mismatch", "missing", "symlink"] {
            let fixture = try RestoreComparisonFixture()
            defer { fixture.remove() }
            await #expect(throws: BackupOperationError.operationFailed) {
                try await fixture.compare { destination in
                    if mode == "mismatch" { try Data("different bytes".utf8).write(to: destination) }
                    if mode == "symlink" {
                        try FileManager.default.createSymbolicLink(
                            at: destination, withDestinationURL: fixture.original)
                    }
                }
            }
            try fixture.expectClean()
        }
    }

    @Test func changedOriginalIsInconclusiveAndIneligibleFilesNeverRestore() async throws {
        let fixture = try RestoreComparisonFixture()
        defer { fixture.remove() }
        let result = try await fixture.compare { destination in
            try fixture.content.write(to: destination)
            try Data("concurrent edit".utf8).write(to: fixture.original)
        }
        #expect(result == false)
        #expect(try await fixture.compare { _ in Issue.record("Ineligible original reached restore") } == nil)
        try fixture.expectClean()
    }

    @Test func processErrorAndCancellationCleanBeforeReturning() async throws {
        let fixture = try RestoreComparisonFixture()
        defer { fixture.remove() }
        await #expect(throws: BackupOperationError.operationFailed) {
            try await fixture.compare { destination in
                try fixture.content.write(to: destination)
                throw BackupOperationError.operationFailed
            }
        }
        try fixture.expectClean()
        let started = ComparisonLatch()
        let task = Task {
            try await fixture.compare { destination in
                try fixture.content.write(to: destination)
                await started.signal()
                try await ContinuousClock().sleep(for: .seconds(60))
            }
        }
        try await waitForRuntime { await started.signalled }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try fixture.expectClean()
    }
}

private struct RestoreComparisonFixture: Sendable {
    let root: URL
    let original: URL
    let sample: KopiaRestoreSample
    let content = Data("test source bytes".utf8)
    init() throws {
        root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        original = root.appendingPathComponent("original")
        try content.write(to: original)
        let modified = try #require(
            original.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        sample = KopiaRestoreSample(
            components: ["original"], objectID: String(repeating: "a", count: 32),
            size: Int64(content.count), modifiedAt: modified)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func compare(_ restore: @Sendable (URL) async throws -> Void) async throws -> Bool? {
        try await RestoreSampleComparison.compare(
            sourcePath: root.path, sample: sample, temporaryDirectory: root, restore: restore)
    }
    func expectClean() throws {
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["original"])
    }
}

private actor ComparisonLatch {
    var signalled = false
    func signal() { signalled = true }
}
