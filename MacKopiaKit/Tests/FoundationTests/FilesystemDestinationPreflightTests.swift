import BackupDomain
import BackupEngine
import Foundation
import SystemIntegration
import Testing

struct FilesystemDestinationPreflightTests {
    private let uuid = UUID().uuidString

    @Test func strictDecimalCapacityThresholdsAndOverflowBoundaries() throws {
        for (available, total, expected) in [
            (0, 100_000_000_000, DestinationCapacityStatus.insufficientSpace),
            (999_999_999, 100_000_000_000, .insufficientSpace),
            (1_000_000_000, 100_000_000_000, .lowSpaceWarning),
            (4_999_999_999, 100_000_000_000, .lowSpaceWarning),
            (5_000_000_000, 100_000_000_000, .sufficient),
            (5_000_000_000, 100_000_000_001, .lowSpaceWarning),
            (5_000_000_001, 100_000_000_001, .sufficient),
            (Int64.max / 20, Int64.max, .lowSpaceWarning),
            (Int64.max / 20 + 1, Int64.max, .sufficient),
            (Int64.max, Int64.max, .sufficient),
            // Important-usage capacity can include reclaimable space; do not clamp it to total.
            (6_000_000_000, 5_000_000_000, .sufficient),
        ] {
            let sample = try observation(available: available, total: total)
            #expect(FilesystemDestinationPreflight.capacityStatus(sample) == expected)
        }
    }

    @Test func samplesValidateIdentityCapacityAndRedactMetadata() throws {
        for (identity, available, total) in [
            ("invalid", Int64(1), Int64(1)), (uuid + "\0", 1, 1), (uuid, -1, 1), (uuid, 0, 0), (uuid, 0, -1),
        ] {
            #expect(throws: VolumeInspectionError.unavailable) {
                try FilesystemDestinationObservation(
                    volumeUUID: identity, isWritable: true, availableBytes: available, totalBytes: total)
            }
        }
        let value = try FilesystemDestinationObservation(
            volumeUUID: uuid.lowercased(), isWritable: true, availableBytes: 12345, totalBytes: 67890)
        #expect(value.volumeUUID == uuid)
        #expect(!String(reflecting: value).contains(uuid))
        #expect(!String(reflecting: value).contains("12345"))
    }

    @Test func identityAndWritePermissionBlockBeforeCapacityIsAdmitted() async throws {
        let expected = try volume()
        let mismatched = try FilesystemDestinationObservation(
            volumeUUID: UUID().uuidString, isWritable: false, availableBytes: 0, totalBytes: 1)
        await #expect(throws: BackupPreflightError.destinationVolumeMismatch) {
            try await FilesystemDestinationPreflight(inspector: FixedDestination(value: mismatched))
                .validate(path: "/Test", expectedVolume: expected)
        }
        let denied = try observation(writable: false)
        await #expect(throws: BackupPreflightError.destinationPermissionDenied) {
            try await FilesystemDestinationPreflight(inspector: FixedDestination(value: denied))
                .validate(path: "/Test", expectedVolume: expected)
        }
        let low = try observation(available: 1)
        #expect(
            try await FilesystemDestinationPreflight(inspector: FixedDestination(value: low))
                .validate(path: "/Test", expectedVolume: expected) == .insufficientSpace)
    }

    @Test func unavailablePermissionAndCancellationStayDistinct() async throws {
        let expected = try volume()
        for (error, mapped) in [
            (VolumeInspectionError.unavailable, BackupPreflightError.destinationUnavailable),
            (.permissionDenied, .destinationPermissionDenied), (.notDirectory, .destinationUnavailable),
        ] {
            await #expect(throws: mapped) {
                try await FilesystemDestinationPreflight(inspector: FailedDestination(error: error))
                    .validate(path: "/Test", expectedVolume: expected)
            }
        }
        await #expect(throws: CancellationError.self) {
            try await FilesystemDestinationPreflight(inspector: FailedDestination(error: CancellationError()))
                .validate(path: "/Test", expectedVolume: expected)
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await FilesystemDestinationPreflight(inspector: UnexpectedDestination())
                    .validate(path: "/Test", expectedVolume: expected)
            }
        }
        await task.value
    }

    @Test func actualTemporaryDirectoryReportsCapacityWithoutCreatingProbeFiles() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destination)
        let inspector = LocalFilesystemDestinationInspector()
        let sample = try await inspector.inspectDestination(at: alias.path)
        let expectedUUID = try #require(destination.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        #expect(sample.volumeUUID == expectedUUID.uppercased())
        #expect(sample.isWritable)
        #expect(sample.availableBytes >= 0)
        #expect(sample.totalBytes > 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        try FileManager.default.removeItem(at: destination)
        await #expect(throws: VolumeInspectionError.self) { try await inspector.inspectDestination(at: alias.path) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let file = root.appendingPathComponent("File")
        try Data().write(to: file)
        await #expect(throws: VolumeInspectionError.notDirectory) {
            try await inspector.inspectDestination(at: file.path)
        }
        await #expect(throws: VolumeInspectionError.invalidPath) {
            try await inspector.inspectDestination(at: "relative")
        }
    }

    @Test func actualWritePermissionIsRefreshedAndCancellationAvoidsInspection() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let inspector = LocalFilesystemDestinationInspector()
        #expect(try await inspector.inspectDestination(at: root.path).isWritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        #expect(try await !inspector.inspectDestination(at: root.path).isWritable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(try await inspector.inspectDestination(at: root.path).isWritable)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await inspector.inspectDestination(at: root.path)
            }
        }
        await cancelled.value
    }

    private func volume() throws -> VolumeIdentity {
        try VolumeIdentity(uuid: uuid, name: "Test", isRemovable: false, isNetwork: false)
    }

    private func observation(
        writable: Bool = true, available: Int64 = 10_000_000_000, total: Int64 = 100_000_000_000
    ) throws -> FilesystemDestinationObservation {
        try FilesystemDestinationObservation(
            volumeUUID: uuid, isWritable: writable, availableBytes: available, totalBytes: total)
    }
}

private struct FixedDestination: FilesystemDestinationInspecting {
    let value: FilesystemDestinationObservation
    func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation { value }
}

private struct FailedDestination: FilesystemDestinationInspecting {
    let error: any Error
    func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation { throw error }
}

private struct UnexpectedDestination: FilesystemDestinationInspecting {
    func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation {
        Issue.record("Cancelled inspection accessed metadata")
        throw VolumeInspectionError.unavailable
    }
}
