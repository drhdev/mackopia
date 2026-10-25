import BackupDomain
import Foundation
import SystemIntegration
import Testing

struct VolumeEjectionSafetyTests {
    @Test func nestedDestinationResolvesToItsVolumesMountPoint() throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let values = try root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey])
        let uuid = try #require(values.volumeUUIDString)
        let expected = try #require(values.volume)
        let volume = try VolumeIdentity(uuid: uuid, name: "Test", isRemovable: false, isNetwork: false)
        let resolved = try LocalVolumeEjector.mountPoint(path: root.path, volume: volume)
        #expect(resolved.standardizedFileURL == expected.standardizedFileURL)
        #expect(resolved != root)
    }

    @Test func identityMismatchAndNonremovableVolumesNeverReachUnmount() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let ejector = LocalVolumeEjector()
        let wrong = try VolumeIdentity(uuid: UUID().uuidString, name: "Stale", isRemovable: true, isNetwork: false)
        await #expect(throws: DomainValidationError.volumeMismatch) {
            try await ejector.eject(path: root.path, volume: wrong)
        }
        let uuid = try #require(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let fixed = try VolumeIdentity(uuid: uuid, name: "System", isRemovable: false, isNetwork: false)
        await #expect(throws: DomainValidationError.volumeUnavailable) {
            try await ejector.eject(path: root.path, volume: fixed)
        }
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}
