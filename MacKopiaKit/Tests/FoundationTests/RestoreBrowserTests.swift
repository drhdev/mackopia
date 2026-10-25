import BackupDomain
import Foundation
import KopiaServer
import Testing

@testable import BackupEngine
@testable import KopiaServer

@Suite("Snapshot-bound restore browser")
struct RestoreBrowserTests {
    @Test func usesManifestSpellingAndRejectsAmbiguousNames() async throws {
        let fixture = RestoreBrowserFixture()
        let nfd = "Überblick.txt".decomposedStringWithCanonicalMapping
        await fixture.setEntries([["name": nfd, "type": "f", "obj": fixture.file]])
        let resolved = try await RestoreBrowser(service: fixture).resolve(
            snapshotID: fixture.snapshot, components: ["Überblick.txt"])
        #expect(Array(resolved.selector.utf8) == Array((fixture.snapshot + "/" + nfd).utf8))
        await fixture.setEntries([
            ["name": nfd, "type": "f", "obj": fixture.file],
            ["name": "Überblick.txt", "type": "f", "obj": fixture.file],
        ])
        await #expect(throws: LocalServiceIssue.invalidRequest) {
            try await RestoreBrowser(service: fixture).resolve(
                snapshotID: fixture.snapshot, components: ["Überblick.txt"])
        }
    }
    @Test func rejectsMissingSnapshotsTraversalAndSymlinkDescent() async throws {
        let fixture = RestoreBrowserFixture()
        let browser = RestoreBrowser(service: fixture)
        await #expect(throws: LocalServiceIssue.invalidRequest) {
            try await browser.resolve(snapshotID: fixture.snapshot, components: [".."])
        }
        #expect(await fixture.sourceCalls == 0)
        await #expect(throws: LocalServiceIssue.invalidRequest) {
            try await browser.resolve(snapshotID: String(repeating: "f", count: 32), components: [])
        }
        await fixture.setEntries([["name": "link", "type": "l", "obj": fixture.file]])
        await #expect(throws: LocalServiceIssue.invalidRequest) {
            try await browser.resolve(snapshotID: fixture.snapshot, components: ["link", "victim"])
        }
    }
    @Test func boundedSearchSignalsIncompleteResultsAndCancellation() async throws {
        let fixture = RestoreBrowserFixture()
        // A cyclic synthetic directory graph must terminate with an explicit limited result.
        await fixture.setEntries([["name": "again", "type": "d", "obj": fixture.root]])
        let result = try await RestoreBrowser(service: fixture).search(snapshotID: fixture.snapshot, query: "again")
        #expect(result.1)
        #expect(result.0.count == 64)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await RestoreBrowser(service: fixture).search(snapshotID: fixture.snapshot, query: "again")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor RestoreBrowserFixture: KopiaRestoreServing {
    nonisolated let snapshot = String(repeating: "b", count: 32)
    nonisolated let root = "k" + String(repeating: "a", count: 32)
    nonisolated let file = String(repeating: "c", count: 32)
    var sourceCalls = 0
    var entries: [[String: String]] = []
    func setEntries(_ values: [[String: String]]) { entries = values }
    private func decode<T: Decodable>(_ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func sources() throws -> KopiaSources {
        try Task.checkCancellation()
        sourceCalls += 1
        return try decode(["sources": [["source": ["userName": "foreign", "host": "other", "path": "/missing"]]]])
    }
    func snapshotManifests(source: KopiaSnapshotSource) throws -> KopiaSnapshots {
        #expect(source.userName == "foreign" && source.host == "other" && source.path == "/missing")
        return try decode(["snapshots": [["id": snapshot, "rootID": root]]])
    }
    func directory(id: String) throws -> KopiaDirectory {
        try Task.checkCancellation()
        #expect(id == root)
        return try decode(["stream": "kopia:directory", "entries": entries])
    }
    func repositoryStatus() throws -> KopiaRepositoryStatus { throw LocalServiceIssue.unavailable }
    func startUpload(source: KopiaSnapshotSource) throws { throw LocalServiceIssue.unavailable }
    func cancelUpload(source: KopiaSnapshotSource) throws { throw LocalServiceIssue.unavailable }
    func pinSnapshot(id: String) throws -> KopiaSnapshot { throw LocalServiceIssue.unavailable }
    func editSnapshot(id: String, description: String, pinned: Bool) throws -> KopiaSnapshot {
        throw LocalServiceIssue.unavailable
    }
    func task(id: String) throws -> KopiaTask { throw LocalServiceIssue.unavailable }
    func startRestore(root: String, destination: String) throws -> KopiaTask { throw LocalServiceIssue.unavailable }
    func cancelTask(id: String) throws { throw LocalServiceIssue.unavailable }
    func policyDefinition(source: KopiaSnapshotSource) throws -> KopiaSourcePolicyDefinition? {
        throw LocalServiceIssue.unavailable
    }
    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) throws -> KopiaPolicyDocument {
        throw LocalServiceIssue.unavailable
    }
    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) throws {
        throw LocalServiceIssue.unavailable
    }
}
