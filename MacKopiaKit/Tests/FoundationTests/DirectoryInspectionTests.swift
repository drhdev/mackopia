import Foundation
import SystemIntegration
import Testing

struct DirectoryInspectionTests {
    @Test func observationRequiresCanonicalPathAndWholeUUIDAndRedactsPrivateMetadata() throws {
        let marker = UUID().uuidString
        let value = try DirectoryObservation(
            canonicalPath: "/" + marker, volumeUUID: UUID().uuidString.lowercased(), isCaseSensitive: true)
        #expect(!String(reflecting: value).contains(marker))
        #expect(value.volumeUUID == value.volumeUUID.uppercased())
        for (path, uuid) in [
            ("relative", UUID().uuidString), ("/Source/../Other", UUID().uuidString),
            ("/Source", "invalid"), ("/Source", UUID().uuidString + "\0"),
        ] {
            #expect(throws: VolumeInspectionError.unavailable) {
                try DirectoryObservation(canonicalPath: path, volumeUUID: uuid, isCaseSensitive: true)
            }
        }
    }

    @Test func freshCanonicalMetadataFollowsSymlinksAndRejectsMissingDirectoriesOrFiles() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Source ü")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
        let inspector = LocalDirectoryInspector()
        let direct = try await inspector.inspectDirectory(at: directory.path)
        #expect(try await inspector.inspectDirectory(at: alias.path) == direct)
        let uuid = try #require(directory.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        #expect(direct.volumeUUID == uuid.uppercased())
        if !direct.isCaseSensitive {
            let alternative = root.appendingPathComponent("sOURCE ü")
            #expect(try await inspector.inspectDirectory(at: alternative.path) == direct)
        }
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        await #expect(throws: VolumeInspectionError.notDirectory) {
            try await inspector.inspectDirectory(at: file.path)
        }
        try FileManager.default.removeItem(at: directory)
        for path in [directory.path, alias.path] {
            await #expect(throws: VolumeInspectionError.self) { try await inspector.inspectDirectory(at: path) }
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func invalidPathsAndCancellationAreRejectedBeforeMetadataAccess() async throws {
        let inspector = LocalDirectoryInspector()
        for path in ["relative", "//Source", "/Source/../Other", "/Source\0Other"] {
            await #expect(throws: VolumeInspectionError.invalidPath) { try await inspector.inspectDirectory(at: path) }
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await inspector.inspectDirectory(at: "/") }
        }
        await task.value
    }
}
