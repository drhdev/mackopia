import BackupDomain
import Foundation
import Synchronization
import Testing

@testable import SystemIntegration

struct VolumeInspectionTests {
    private func volume(uuid: String) throws -> VolumeIdentity {
        try VolumeIdentity(uuid: uuid, name: "Test", isRemovable: true, isNetwork: false)
    }

    @Test func guardReadsTheExactSourcePathAndChecksUUID() async throws {
        let uuid = UUID().uuidString
        let resources = RecordingVolumeResources(.success(uuid.lowercased()))
        let inspector = LocalVolumeInspector(resources: resources)
        let guarder = VolumeIdentityGuard(inspector: inspector)
        let source = try BackupSource(path: "/Volumes/Test/Quelle ü %2F", volume: volume(uuid: uuid))
        try await guarder.validateSource(source)
        #expect(resources.paths == [source.path])
        let other = try volume(uuid: UUID().uuidString)
        await #expect(throws: DomainValidationError.volumeMismatch) {
            try await guarder.validateDirectory(path: source.path, expected: other)
        }
        #expect(resources.paths == [source.path, source.path])
    }

    @Test func invalidPathsNeverReachFilesystemReader() async throws {
        let resources = RecordingVolumeResources(.success(UUID().uuidString))
        let inspector = LocalVolumeInspector(resources: resources)
        let guarder = VolumeIdentityGuard(inspector: inspector)
        let expected = try volume(uuid: UUID().uuidString)
        for path in ["relative", "", "/Test/../Other", "/Test\0Other", "//Test"] {
            await #expect(throws: VolumeInspectionError.invalidPath) {
                try await inspector.volumeUUID(forDirectory: path)
            }
            await #expect(throws: VolumeInspectionError.invalidPath) {
                try await guarder.validateDirectory(path: path, expected: expected)
            }
        }
        #expect(resources.paths.isEmpty)
    }

    @Test func absentOrMalformedVolumeUUIDNeverPassesPreflight() async throws {
        for uuid in [nil, "", "invalid", UUID().uuidString + "\0"] {
            let resources = RecordingVolumeResources(.success(uuid))
            let guarder = VolumeIdentityGuard(inspector: LocalVolumeInspector(resources: resources))
            let expected = try volume(uuid: UUID().uuidString)
            await #expect(throws: VolumeInspectionError.unavailable) {
                try await guarder.validateDirectory(path: "/Test", expected: expected)
            }
            #expect(resources.paths == ["/Test"])
        }
    }

    @Test func systemFailuresAreClassifiedWithoutLeakingDiagnostics() async throws {
        let marker = UUID().uuidString
        for (error, expected) in [
            (
                NSError(
                    domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
                    userInfo: [NSFilePathErrorKey: marker]), VolumeInspectionError.permissionDenied
            ),
            (
                NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSFilePathErrorKey: marker]),
                .permissionDenied
            ),
            (NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: nil), .permissionDenied),
            (
                NSError(
                    domain: NSCocoaErrorDomain, code: CocoaError.fileNoSuchFile.rawValue,
                    userInfo: [NSFilePathErrorKey: marker]), .unavailable
            ),
        ] {
            let inspector = LocalVolumeInspector(resources: RecordingVolumeResources(.failure(error)))
            await #expect(throws: expected) { try await inspector.volumeUUID(forDirectory: "/Test") }
            #expect(!expected.debugDescription.contains(marker))
            #expect(!expected.localizedDescription.contains(marker))
        }
    }

    @Test func alreadyCancelledPreflightDoesNotReadMetadata() async throws {
        let resources = RecordingVolumeResources(.success(UUID().uuidString))
        let inspector = LocalVolumeInspector(resources: resources)
        let guarder = VolumeIdentityGuard(inspector: inspector)
        let expected = try volume(uuid: UUID().uuidString)
        let task = Task<Void, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await inspector.volumeUUID(forDirectory: "/Test") }
            await #expect(throws: CancellationError.self) {
                try await guarder.validateDirectory(path: "/Test", expected: expected)
            }
        }
        await task.value
        #expect(resources.paths.isEmpty)
    }

    @Test func cancellationDuringObservationCannotApproveTheVolume() async throws {
        let expected = try volume(uuid: UUID().uuidString)
        let guarder = VolumeIdentityGuard(inspector: CancellingVolumeInspector(uuid: expected.uuid))
        let task = Task<Void, Never> {
            await #expect(throws: CancellationError.self) {
                try await guarder.validateDirectory(path: "/Test", expected: expected)
            }
        }
        await task.value
    }

    @Test func cancellationDuringMetadataReadOverridesItsResultOrFailure() async throws {
        for result in [
            Result<String?, any Error>.success(UUID().uuidString),
            .failure(VolumeInspectionError.notDirectory),
        ] {
            let inspector = LocalVolumeInspector(resources: RecordingVolumeResources(result, cancelDuringRead: true))
            let task = Task<Void, Never> {
                await #expect(throws: CancellationError.self) { try await inspector.volumeUUID(forDirectory: "/Test") }
            }
            await task.value
        }
    }

    @Test func realDirectoryAndSymlinkResolveToTheActualVolume() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let actual = try #require(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let directory = root.appendingPathComponent("Quelle ü %2F")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("Source link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        let inspector = LocalVolumeInspector()
        #expect(try await inspector.volumeUUID(forDirectory: directory.path) == actual.uppercased())
        #expect(try await inspector.volumeUUID(forDirectory: link.path) == actual.uppercased())
        let source = try BackupSource(path: link.path, volume: volume(uuid: actual))
        try await VolumeIdentityGuard(inspector: inspector).validateSource(source)
        try FileManager.default.removeItem(at: directory)
        await #expect(throws: VolumeInspectionError.self) { try await inspector.volumeUUID(forDirectory: link.path) }
    }

    @Test func realEmptyMountPointOnWrongVolumeIsRejected() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mountPoint = root.appendingPathComponent("Missing backup drive")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
        let inspector = LocalVolumeInspector()
        let actual = try await inspector.volumeUUID(forDirectory: mountPoint.path)
        let disconnectedVolume = try volume(uuid: UUID().uuidString)
        #expect(disconnectedVolume.uuid != actual)
        let guarder = VolumeIdentityGuard(inspector: inspector)
        await #expect(throws: DomainValidationError.volumeMismatch) {
            try await guarder.validateDirectory(path: mountPoint.path, expected: disconnectedVolume)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: mountPoint.path).isEmpty)
    }

    @Test func realMissingDirectoryAndRegularFileHaveNoParentFallback() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let link = root.appendingPathComponent("file link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let inspector = LocalVolumeInspector()
        for path in [root.appendingPathComponent("missing").path, file.path, link.path] {
            await #expect(throws: VolumeInspectionError.self) { try await inspector.volumeUUID(forDirectory: path) }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
    }
}

private final class RecordingVolumeResources: VolumeResourceReading {
    private let result: Result<String?, any Error>
    private let cancelDuringRead: Bool
    private let recordedPaths = Mutex<[String]>([])
    var paths: [String] { recordedPaths.withLock { $0 } }

    init(_ result: Result<String?, any Error>, cancelDuringRead: Bool = false) {
        self.result = result
        self.cancelDuringRead = cancelDuringRead
    }
    func volumeUUID(forDirectory url: URL) throws -> String? {
        recordedPaths.withLock { $0.append(url.path) }
        if cancelDuringRead { withUnsafeCurrentTask { $0?.cancel() } }
        return try result.get()
    }
}

private struct CancellingVolumeInspector: VolumeInspecting {
    let uuid: String
    func volumeUUID(forDirectory path: String) async throws -> String {
        withUnsafeCurrentTask { $0?.cancel() }
        return uuid
    }
}
