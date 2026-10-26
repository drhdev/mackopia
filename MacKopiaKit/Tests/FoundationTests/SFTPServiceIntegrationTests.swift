import BackupDomain
import Foundation
import Secrets
import Testing

@testable import BackupEngine
@testable import KopiaCLI

@Suite(
    "SFTP service lifecycle", .tags(.integration),
    .enabled(if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)))
struct SFTPServiceIntegrationTests {
    @Test func createBackupRestoreReconnectAndRejectWrongCredentials() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await SFTPFixture(root: root)
        defer { fixture.close() }
        let source = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("output")
        for folder in [source, output] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bytes = Data(UUID().uuidString.utf8)
        try bytes.write(to: source.appendingPathComponent("hello.txt"))
        let secrets = ServiceTestSecrets()
        var setup = try SFTPSetup(
            host: "127.0.0.1", port: fixture.port, username: fixture.username,
            path: root.appendingPathComponent("storage").path, hostKey: fixture.hostKey, hostKeyConfirmed: true,
            privateKey: fixture.encryptedKey, passphrase: fixture.passphrase, backupPassword: UUID().uuidString)
        let service = try makeService(root: root, home: root, secrets: secrets)
        try await service.start()
        var stage = "setup"
        do {
            try await service.setupSFTP(name: "SFTP", source: selection(source), setup: setup, create: true)
            let repository = try #require(try await service.state().configuration?.repositories.first)
            let stored = try #require(await secrets.read(repository.secretRef))
            setup = try JSONDecoder().decode(SFTPSetup.self, from: stored.data)
            #expect(setup.passphrase.isEmpty)
            let keyMatches = setup.privateKey == fixture.privateKey
            #expect(keyMatches)
            let plan = try #require(try await service.state().configuration?.plans.first)
            stage = "duplicate endpoint with fresh key reference"
            let sameDestination = try SFTPSetup(
                host: setup.host.uppercased(), port: setup.port,
                username: setup.username, path: setup.path, hostKey: setup.hostKey, hostKeyConfirmed: true,
                privateKey: setup.privateKey, backupPassword: setup.backupPassword)
            await #expect(throws: LocalServiceIssue.destination) {
                try await service.setupSFTP(
                    name: "Duplicate", source: selection(source), setup: sameDestination, create: false)
            }
            #expect(try await service.state().configuration?.repositories.count == 1)
            stage = "duplicate create"
            let format = root.appendingPathComponent("storage/kopia.repository.f")
            let originalFormat = try Data(contentsOf: format)
            let duplicate = try makeService(
                root: root, home: root.appendingPathComponent("duplicate"), secrets: secrets)
            try await duplicate.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await duplicate.setupSFTP(
                    name: "Duplicate", source: selection(source), setup: setup, create: true)
            }
            #expect(try Data(contentsOf: format) == originalFormat)
            #expect(try await duplicate.state().configuration?.repositories.isEmpty == true)
            await duplicate.shutdown()
            stage = "backup"
            try await service.run(plan.id)
            try await waitForRuntime(timeout: .seconds(90)) {
                let state = try await service.state()
                // History is published before the active-plan observation can catch up during admission.
                // Wait for a terminal run as well as released execution, retaining every success assertion below.
                return state.runs.first.map { $0.outcome != .running } == true && state.activePlanID == nil
            }
            let state = try await service.state()
            #expect(state.runs.first?.outcome == .succeeded)
            #expect(state.plans.first?.verification?.outcome == .succeeded)
            #expect(state.plans.first?.testRestore?.outcome == .succeeded)
            let snapshot = try #require(state.runs.first?.sources.first?.snapshotID)
            stage = "credential replacement"
            let originalCredential = try #require(await secrets.read(repository.secretRef))
            func replacement(key: String, password: String) throws -> SFTPSetup {
                try SFTPSetup(
                    host: setup.host, port: setup.port, username: setup.username, path: setup.path,
                    hostKey: setup.hostKey, hostKeyConfirmed: true, privateKey: key,
                    backupPassword: password, keyRef: setup.keyRef)
            }
            let invalidCredentials = [
                try replacement(key: fixture.wrongKey, password: setup.backupPassword),
                try replacement(key: setup.privateKey, password: UUID().uuidString),
            ]
            for invalid in invalidCredentials {
                await #expect(throws: LocalServiceIssue.destination) {
                    try await service.updateSFTPCredentials(repositoryID: repository.id, setup: invalid)
                }
                #expect(await secrets.read(repository.secretRef)?.data == originalCredential.data)
            }
            let wrongPassphrase = try SFTPSetup(
                host: setup.host, port: setup.port, username: setup.username,
                path: setup.path, hostKey: setup.hostKey, hostKeyConfirmed: true,
                privateKey: fixture.encryptedKey, passphrase: UUID().uuidString,
                backupPassword: setup.backupPassword, keyRef: setup.keyRef)
            await #expect(throws: (any Error).self) {
                try await service.updateSFTPCredentials(repositoryID: repository.id, setup: wrongPassphrase)
            }
            #expect(await secrets.read(repository.secretRef)?.data == originalCredential.data)
            try await service.updateSFTPCredentials(repositoryID: repository.id, setup: setup)
            stage = "verify"
            try await service.verify(plan.id)
            try await waitForRuntime(timeout: .seconds(60)) { try await service.state().activePlanID == nil }
            #expect(try await service.state().plans.first?.verification?.filesPercent == 1)
            await service.shutdown()
            let reopened = try makeService(root: root, home: root, secrets: secrets)
            try await reopened.start()
            try FileManager.default.removeItem(at: source)
            stage = "reopened browse"
            try await reopened.browse(repositoryID: repository.id, snapshotID: snapshot, components: [])
            #expect(try await reopened.state().restore?.entries.contains(where: { $0.name == "hello.txt" }) == true)
            stage = "restore"
            try await reopened.restore(
                repositoryID: repository.id, snapshotID: snapshot, components: [], destination: selection(output))
            try await waitForRuntime(timeout: .seconds(60)) { try await reopened.state().restore?.phase != .running }
            let restore = try #require(try await reopened.state().restore)
            #expect(restore.phase == .succeeded)
            let restored = URL(fileURLWithPath: try #require(restore.destination)).appendingPathComponent("hello.txt")
            #expect(try Data(contentsOf: restored) == bytes)
            await reopened.shutdown()
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let originalPaths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
            let payload = try KopiaSFTPSetup.configuration(repository: repository, home: root, setup: setup)
            let context = KopiaExecutionContext(
                executable: NativeKopiaFixture.binary, paths: originalPaths,
                temporaryDirectory: root, user: NSUserName(), configuration: .webDAV(payload),
                backupPassword: setup.backupPassword)
            let base = context.request(for: .repositoryStatus)
            let ownerChange = try await KopiaProcess().run(
                KopiaProcessRequest(
                    executable: NativeKopiaFixture.binary,
                    arguments: Array(base.arguments.dropLast(3)) + ["maintenance", "set", "--owner=foreign@host"],
                    environment: base.environment, webDAVConfiguration: base.webDAVConfiguration,
                    repositoryDirectory: base.repositoryDirectory))
            #expect(ownerChange.exitCode == 0)
            let connected = try makeService(
                root: root, home: root.appendingPathComponent("connected"), secrets: secrets)
            try await connected.start()
            stage = "connect"
            try await connected.setupSFTP(name: "Connected", source: selection(source), setup: setup, create: false)
            let second = try #require(try await connected.state().configuration?.repositories.first)
            let maintenance = try await KopiaMaintenanceReader().read(
                executable: NativeKopiaFixture.binary,
                paths: KopiaRepositoryPaths(
                    repositoryID: second.id, homeDirectory: root.appendingPathComponent("connected")),
                temporaryDirectory: root, user: NSUserName(), backupPassword: setup.backupPassword, lowPriority: true,
                webDAV: KopiaSFTPSetup.configuration(
                    repository: second, home: root.appendingPathComponent("connected"), setup: setup))
            #expect(try maintenance.fullMaintenance(identity: second.identity, at: .now) == .foreignOwner)
            stage = "connected browse"
            try await connected.browse(repositoryID: second.id, snapshotID: snapshot, components: [])
            #expect(try await connected.state().restore?.snapshots.isEmpty == false)
            await connected.shutdown()
            stage = "denied credentials"
            let bad = try replacement(key: fixture.wrongKey, password: setup.backupPassword)
            let denied = try makeService(root: root, home: root.appendingPathComponent("denied"), secrets: secrets)
            try await denied.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await denied.setupSFTP(name: "Denied", source: selection(source), setup: bad, create: false)
            }
            #expect(try await denied.state().configuration?.repositories.isEmpty == true)
            await denied.shutdown()
            stage = "host key mismatch"
            let clientPublic = try String(
                contentsOf: root.appendingPathComponent("ssh/authorized_keys"), encoding: .utf8
            )
            .split(whereSeparator: { $0.isWhitespace }).prefix(2).joined(separator: " ")
            let wrongHost = try SFTPSetup(
                host: setup.host, port: setup.port, username: setup.username,
                path: setup.path, hostKey: clientPublic, hostKeyConfirmed: true,
                privateKey: setup.privateKey, backupPassword: setup.backupPassword)
            let mismatched = try makeService(
                root: root, home: root.appendingPathComponent("mismatch"), secrets: secrets)
            try await mismatched.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await mismatched.setupSFTP(
                    name: "Mismatch", source: selection(source), setup: wrongHost, create: false)
            }
            #expect(try await mismatched.state().configuration?.repositories.isEmpty == true)
            await mismatched.shutdown()
            stage = "offline"
            fixture.close()
            let offline = try makeService(root: root, home: root.appendingPathComponent("offline"), secrets: secrets)
            try await offline.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await offline.setupSFTP(name: "Offline", source: selection(source), setup: setup, create: false)
            }
            #expect(try await offline.state().configuration?.repositories.isEmpty == true)
            await offline.shutdown()
            let isolated = try FileManager.default.contentsOfDirectory(
                atPath: originalPaths.configurationDirectory.path)
            #expect(!isolated.contains("repository.config"))
            #expect(!isolated.contains(where: { $0.hasPrefix("runtime-") }))
            let enumerator = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            while let file = enumerator.nextObject() as? URL {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let data = try Data(contentsOf: file)
                    for secret in [
                        setup.privateKey, setup.backupPassword, fixture.wrongKey,
                        String(setup.privateKey.split(separator: "\n")[1]),
                    ]
                        + invalidCredentials.map({ $0.backupPassword })
                    {
                        #expect(data.range(of: Data(secret.utf8)) == nil)
                    }
                }
            }
        } catch {
            Issue.record("SFTP lifecycle failed during \(stage)")
            await service.shutdown()
            throw error
        }
    }

    private func makeService(root: URL, home: URL, secrets: ServiceTestSecrets) throws -> LocalBackupService {
        try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: home, temporary: root, expectedVersion: "0.23.1",
            secrets: secrets, sourceAccess: SFTPTemporaryAccess(root: root),
            protection: LocalBackupOperationProtection(), monitor: RuntimeMonitor())
    }
    private func selection(_ url: URL) throws -> BackupSource {
        try BackupSource(
            path: url.path,
            volume: VolumeIdentity(
                uuid: #require(url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString), name: "Temporary",
                isRemovable: false, isNetwork: false))
    }
}

private struct SFTPTemporaryAccess: SourceAccessChecking {
    let root: URL
    func checkAccess(to sources: [BackupSource]) throws -> PreflightAccessStatus {
        sources.allSatisfy { $0.path.hasPrefix(root.path + "/") } ? .verified : .denied
    }
}
