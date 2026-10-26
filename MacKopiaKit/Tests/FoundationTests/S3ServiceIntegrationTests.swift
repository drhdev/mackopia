import BackupDomain
import Foundation
import Secrets
import Testing

@testable import BackupEngine
@testable import KopiaCLI

@Suite(
    "S3 service lifecycle", .tags(.integration),
    .enabled(if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)))
struct S3ServiceIntegrationTests {
    @Test func createBackupRestoreReconnectAndRejectWrongCredentials() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await S3Fixture(root: root)
        defer { fixture.close() }
        let source = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("output")
        for folder in [source, output] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bytes = Data(UUID().uuidString.utf8)
        try bytes.write(to: source.appendingPathComponent("hello.txt"))
        let secrets = ServiceTestSecrets()
        let setup = try S3Setup(
            endpoint: fixture.endpoint, bucket: "bucket", prefix: "backups/test/", region: "us-east-1",
            password: UUID().uuidString, accessKey: fixture.access, secretKey: fixture.secret,
            sessionToken: fixture.token)
        let service = try makeService(root: root, home: root, secrets: secrets)
        try await service.start()
        var stage = "setup"
        do {
            try await service.setupS3(name: "S3", source: selection(source), setup: setup, create: true)
            let repository = try #require(try await service.state().configuration?.repositories.first)
            let plan = try #require(try await service.state().configuration?.plans.first)
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
            let invalidCredentials = [
                try S3Setup(
                    endpoint: setup.endpoint, bucket: setup.bucket, prefix: setup.prefix, region: setup.region,
                    password: setup.password, accessKey: setup.accessKey, secretKey: UUID().uuidString,
                    sessionToken: setup.sessionToken),
                try S3Setup(
                    endpoint: setup.endpoint, bucket: setup.bucket, prefix: setup.prefix, region: setup.region,
                    password: setup.password, accessKey: setup.accessKey, secretKey: setup.secretKey,
                    sessionToken: UUID().uuidString),
                try S3Setup(
                    endpoint: setup.endpoint, bucket: setup.bucket, prefix: setup.prefix, region: setup.region,
                    password: UUID().uuidString, accessKey: setup.accessKey, secretKey: setup.secretKey,
                    sessionToken: setup.sessionToken),
            ]
            for invalid in invalidCredentials {
                await #expect(throws: LocalServiceIssue.destination) {
                    try await service.updateS3Credentials(repositoryID: repository.id, setup: invalid)
                }
                #expect(await secrets.read(repository.secretRef)?.data == originalCredential.data)
            }
            try await service.updateS3Credentials(repositoryID: repository.id, setup: setup)
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
            let authentication = try KopiaS3Authentication(
                accessKey: setup.accessKey, secretKey: setup.secretKey,
                sessionToken: setup.sessionToken)
            let originalPaths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
            let context = KopiaExecutionContext(
                executable: NativeKopiaFixture.binary,
                paths: originalPaths, temporaryDirectory: root,
                user: NSUserName(), configuration: .file, backupPassword: setup.password, s3: authentication)
            let base = context.request(for: .repositoryStatus)
            let ownerChange = try await KopiaProcess().run(
                KopiaProcessRequest(
                    executable: NativeKopiaFixture.binary,
                    arguments: Array(base.arguments.dropLast(3)) + ["maintenance", "set", "--owner=foreign@host"],
                    environment: base.environment))
            #expect(ownerChange.exitCode == 0)
            let connected = try makeService(
                root: root, home: root.appendingPathComponent("connected"), secrets: secrets)
            try await connected.start()
            stage = "connect"
            try await connected.setupS3(name: "Connected", source: selection(source), setup: setup, create: false)
            let second = try #require(try await connected.state().configuration?.repositories.first)
            let maintenance = try await KopiaMaintenanceReader().read(
                executable: NativeKopiaFixture.binary,
                paths: KopiaRepositoryPaths(
                    repositoryID: second.id, homeDirectory: root.appendingPathComponent("connected")),
                temporaryDirectory: root, user: NSUserName(), backupPassword: setup.password, lowPriority: true,
                s3: authentication)
            #expect(try maintenance.fullMaintenance(identity: second.identity, at: .now) == .foreignOwner)
            stage = "connected browse"
            try await connected.browse(repositoryID: second.id, snapshotID: snapshot, components: [])
            #expect(try await connected.state().restore?.snapshots.isEmpty == false)
            await connected.shutdown()
            stage = "denied credentials"
            let bad = try S3Setup(
                endpoint: setup.endpoint, bucket: setup.bucket, prefix: setup.prefix, region: setup.region,
                password: setup.password, accessKey: setup.accessKey, secretKey: UUID().uuidString,
                sessionToken: setup.sessionToken)
            let denied = try makeService(root: root, home: root.appendingPathComponent("denied"), secrets: secrets)
            try await denied.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await denied.setupS3(name: "Denied", source: selection(source), setup: bad, create: false)
            }
            #expect(try await denied.state().configuration?.repositories.isEmpty == true)
            await denied.shutdown()
            stage = "offline"
            fixture.close()
            let offline = try makeService(root: root, home: root.appendingPathComponent("offline"), secrets: secrets)
            try await offline.start()
            await #expect(throws: LocalServiceIssue.destination) {
                try await offline.setupS3(name: "Offline", source: selection(source), setup: setup, create: false)
            }
            #expect(try await offline.state().configuration?.repositories.isEmpty == true)
            await offline.shutdown()
            let enumerator = try #require(
                FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            while let file = enumerator.nextObject() as? URL {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    let data = try Data(contentsOf: file)
                    for secret in [setup.password, fixture.access, fixture.secret, fixture.token, bad.secretKey]
                        + invalidCredentials.flatMap({ [$0.password, $0.secretKey, $0.sessionToken] })
                    {
                        #expect(data.range(of: Data(secret.utf8)) == nil)
                    }
                }
            }
        } catch {
            Issue.record("S3 lifecycle failed during \(stage)")
            await service.shutdown()
            throw error
        }
    }

    @Test func accessKeysWithoutSessionTokenCanCreateAndReopen() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try await S3Fixture(root: root, useSessionToken: false)
        defer { fixture.close() }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let secrets = ServiceTestSecrets()
        let setup = try S3Setup(
            endpoint: fixture.endpoint, bucket: "bucket", prefix: "", region: "us-east-1",
            password: UUID().uuidString, accessKey: fixture.access, secretKey: fixture.secret)
        for create in [true, false] {
            let home = root.appendingPathComponent(create ? "creating" : "connecting")
            let service = try makeService(root: root, home: home, secrets: secrets)
            try await service.start()
            do {
                try await service.setupS3(name: "S3", source: selection(source), setup: setup, create: create)
                let repository = try #require(try await service.state().configuration?.repositories.first)
                try await service.browse(repositoryID: repository.id, snapshotID: nil, components: [])
                #expect(try await service.state().restore?.snapshots.isEmpty == true)
                await service.shutdown()
            } catch { await service.shutdown(); throw error }
        }
    }

    private func makeService(root: URL, home: URL, secrets: ServiceTestSecrets) throws -> LocalBackupService {
        try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: home, temporary: root, expectedVersion: "0.23.1",
            secrets: secrets, sourceAccess: S3TemporaryAccess(root: root),
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

private struct S3TemporaryAccess: SourceAccessChecking {
    let root: URL
    func checkAccess(to sources: [BackupSource]) throws -> PreflightAccessStatus {
        sources.allSatisfy { $0.path.hasPrefix(root.path + "/") } ? .verified : .denied
    }
}
