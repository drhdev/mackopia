import BackupDomain
import Foundation
import Persistence
import Secrets
import Testing

@testable import BackupEngine

struct LocalBackupServiceTests {
    @Test func firstLaunchObservationCancellationAndShutdownAreSafe() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = try fixture(root)
        try await service.start()
        let initial = try await service.state()
        #expect(initial.configuration?.plans.isEmpty == true)
        #expect(initial.issue == nil)
        await #expect(throws: LocalServiceIssue.invalidRequest) { try await service.run(UUID()) }
        await #expect(throws: LocalServiceIssue.invalidRequest) { try await service.stop(UUID()) }
        let observer = Task { try await service.state(after: initial.revision) }
        observer.cancel()
        await #expect(throws: CancellationError.self) { try await observer.value }
        await service.shutdown()
        await #expect(throws: LocalServiceIssue.unavailable) { try await service.run(UUID()) }
    }

    @Test func malformedConfigurationNeverBecomesEmptyOrWritable() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("Library/Application Support/MacKopia")
        try FileManager.default.createDirectory(
            at: config, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = config.appendingPathComponent("config.json")
        try Data("invalid".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let service = try fixture(root)
        try await service.start()
        let state = try await service.state()
        #expect(state.configuration == nil)
        #expect(state.issue == .safeMode)
        let selected = try BackupSource(
            path: root.path,
            volume: VolumeIdentity(
                uuid: "11111111-1111-1111-1111-111111111111", name: "Test", isRemovable: false, isNetwork: false))
        await #expect(throws: LocalServiceIssue.safeMode) {
            try await service.setup(
                name: "Test", destination: selected, source: selected, password: UUID().uuidString, create: true)
        }
        #expect(try Data(contentsOf: file) == Data("invalid".utf8))
        await service.shutdown()
    }

    @Test func recoveryRequiresExplicitActionAndKeepsBackupsIntact() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Library/Application Support/MacKopia")
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let store = try ConfigStore(directory: directory)
        _ = try await store.load()
        let empty = try BackupConfiguration()
        try await store.save(empty)
        try await store.save(empty)
        let file = directory.appendingPathComponent("config.json")
        let backup = try Data(contentsOf: directory.appendingPathComponent("config.json.bak"))
        try Data("broken".utf8).write(to: file)
        let service = try fixture(root)
        try await service.start()
        #expect(try await service.state().issue == .safeMode)
        try await service.recoverConfiguration()
        #expect(try await service.state().configuration == empty)
        #expect(try await service.state().issue == nil)
        #expect(try Data(contentsOf: directory.appendingPathComponent("config.json.bak")) == backup)
        await service.shutdown()
    }

    @Test func staleSelectedVolumeCannotWriteSecretOrCreateRepository() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        let source = root.appendingPathComponent("source")
        for folder in [destination, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let wrongVolume = try VolumeIdentity(
            uuid: "11111111-1111-1111-1111-111111111111", name: "Stale", isRemovable: false, isNetwork: false)
        let secrets = ServiceTestSecrets()
        let service = try LocalBackupService(
            executable: root.appendingPathComponent("absent"), home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: secrets, sourceAccess: UnknownPreflightObservations(),
            protection: ManualTestProtection())
        try await service.start()
        await #expect(throws: DomainValidationError.volumeMismatch) {
            try await service.setup(
                name: "Test", destination: BackupSource(path: destination.path, volume: wrongVolume),
                source: BackupSource(path: source.path, volume: wrongVolume), password: UUID().uuidString, create: true)
        }
        #expect(await secrets.writeCount == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(try await service.state().configuration?.repositories.isEmpty == true)
        await service.shutdown()
    }

    private func fixture(_ root: URL) throws -> LocalBackupService {
        try LocalBackupService(
            executable: root.appendingPathComponent("absent"), home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: ServiceTestSecrets(), sourceAccess: UnknownPreflightObservations(),
            protection: ManualTestProtection())
    }
}

actor ServiceTestSecrets: SecretStore {
    private var values: [SecretRef: SecretValue] = [:]
    private(set) var writeCount = 0
    func read(_ reference: SecretRef) -> SecretValue? { values[reference] }
    func write(_ value: SecretValue, for reference: SecretRef) { writeCount += 1; values[reference] = value }
    func delete(_ reference: SecretRef) { values.removeValue(forKey: reference) }
}
