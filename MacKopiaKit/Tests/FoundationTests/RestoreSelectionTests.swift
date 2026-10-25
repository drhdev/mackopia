import BackupDomain
import Foundation
import Testing

@testable import AgentProtocol
@testable import BackupEngine

@Suite("Restore request boundaries")
struct RestoreSelectionTests {
    @Test func rejectsTraversalAndUnboundedSelections() throws {
        let id = String(repeating: "a", count: 32)
        for path in [
            [".."], ["."], ["a/b"], ["a\0b"], [""], [String(repeating: "a", count: 256)],
            Array(repeating: "a", count: 65),
        ] {
            #expect(throws: LocalServiceIssue.invalidRequest) {
                try AgentRequest(.browse(repositoryID: UUID(), snapshotID: id, components: path)).validate()
            }
        }
        for invalid in ["", "../manifest", "https://example.org", String(repeating: "a", count: 129)] {
            #expect(throws: LocalServiceIssue.invalidRequest) {
                try RestoreSelection.validate(snapshotID: invalid, components: [])
            }
        }
        try AgentRequest(.browse(repositoryID: UUID(), snapshotID: id, components: ["Documents", "Überblick.txt"]))
            .validate()
        #expect(throws: LocalServiceIssue.invalidRequest) {
            try AgentRequest(.searchRestore(repositoryID: UUID(), snapshotID: id, query: "")).validate()
        }
        #expect(throws: LocalServiceIssue.invalidRequest) {
            try AgentRequest(.previewRestore(repositoryID: UUID(), snapshotID: id, components: [])).validate()
        }
    }

    @Test func privateDestinationsNeverReuseAnExistingPath() throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let volume = try identity(root)
        let repository = try Repository(
            name: "Temp", kind: .filesystem(path: destination.path, volume: volume),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
        let parent = try BackupSource(path: root.path, volume: volume)
        let first = try RestoreDestination.create(parent: parent, repository: repository)
        let second = try RestoreDestination.create(parent: parent, repository: repository)
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: first.deletingLastPathComponent().path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(throws: LocalServiceIssue.destination) {
            try RestoreDestination.create(
                parent: BackupSource(path: destination.path, volume: volume), repository: repository)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: LocalServiceIssue.destination) {
            try RestoreDestination.create(parent: BackupSource(path: link.path, volume: volume), repository: repository)
        }
        let wrong = try VolumeIdentity(uuid: UUID().uuidString, name: "Wrong", isRemovable: false, isNetwork: false)
        #expect(throws: DomainValidationError.volumeMismatch) {
            try RestoreDestination.create(parent: BackupSource(path: root.path, volume: wrong), repository: repository)
        }
    }
    private func identity(_ url: URL) throws -> VolumeIdentity {
        try VolumeIdentity(
            uuid: #require(url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString),
            name: "Temp", isRemovable: false, isNetwork: false)
    }
}
