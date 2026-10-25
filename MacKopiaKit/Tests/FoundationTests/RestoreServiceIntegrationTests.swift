import BackupDomain
import CryptoKit
import Foundation
import Secrets
import Testing

@testable import BackupEngine
@testable import KopiaCLI

@Suite(
    "Restore service with pinned Kopia", .tags(.integration),
    .enabled(if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)))
struct RestoreServiceIntegrationTests {
    @Test func browseSearchRestoreWithoutOriginalAndPreviewCleanup() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let repo = root.appendingPathComponent("repository")
        let output = root.appendingPathComponent("output")
        let nested = source.appendingPathComponent("nested")
        for folder in [source, repo, output, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        let bytes = Data("Private file, Unicode ä and symbols + #".utf8)
        let file = nested.appendingPathComponent("Überblick + #.txt")
        try bytes.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640, .modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: file.path)
        try Data().write(to: source.appendingPathComponent("empty"))
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link").path, withDestinationPath: "nested/Überblick + #.txt")
        let secrets = ServiceTestSecrets()
        let service = try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: secrets, sourceAccess: RestoreTemporaryAccess(root: root),
            protection: LocalBackupOperationProtection(), monitor: RuntimeMonitor())
        try await service.start()
        let password = UUID().uuidString
        try await service.setup(
            name: "Temporary", destination: selection(repo), source: selection(source),
            password: password, create: true)
        let config = try #require(try await service.state().configuration)
        let plan = try #require(config.plans.first)
        let repository = try #require(config.repositories.first)
        try await service.run(plan.id)
        try await waitForRuntime(timeout: .seconds(45)) {
            let state = try await service.state()
            return state.runs.count == 1 && state.runs.first?.outcome != .running && state.activePlanID == nil
        }
        #expect(try await service.state().runs.first?.outcome == .succeeded)
        // A separate isolated connection adds a snapshot from a different user and computer.
        let foreign = try Repository(
            name: "Foreign", kind: repository.kind,
            identity: SnapshotIdentity(overrideUser: "foreign-user", overrideHost: "foreign-host"),
            secretRef: SecretRef())
        try await KopiaLocalSetup(
            executable: NativeKopiaFixture.binary, home: root, temporary: root, user: NSUserName()
        )
        .perform(repository: foreign, password: password, create: false)
        let foreignPaths = try KopiaRepositoryPaths(repositoryID: foreign.id, homeDirectory: root)
        let context = KopiaExecutionContext(
            executable: NativeKopiaFixture.binary, paths: foreignPaths,
            temporaryDirectory: root, user: NSUserName(), configuration: .file, backupPassword: password)
        let base = context.request(for: .repositoryStatus)
        let request = KopiaProcessRequest(
            executable: base.executable,
            arguments: Array(base.arguments.dropLast(3)) + ["snapshot", "create", source.path, "--json"],
            environment: base.environment)
        #expect(try await KopiaProcess().run(request).exitCode == 0)
        // The original source is deliberately unavailable for every browser and restore call below.
        try FileManager.default.removeItem(at: source)
        try await service.browse(repositoryID: repository.id, snapshotID: nil, components: [])
        let catalog = try #require(try await service.state().restore)
        let snapshot = try #require(catalog.snapshots.first { $0.user == "foreign-user" && $0.host == "foreign-host" })
        #expect(snapshot.sourcePath == source.path)
        try await service.browse(repositoryID: repository.id, snapshotID: snapshot.id, components: ["nested"])
        #expect(try await service.state().restore?.entries.first?.name == "Überblick + #.txt")
        try await service.searchRestore(repositoryID: repository.id, snapshotID: snapshot.id, query: "überblick")
        #expect(try await service.state().restore?.matches.first?.components == ["nested", "Überblick + #.txt"])
        // Existing conflicting data in the selected parent remains byte-for-byte unchanged.
        let conflict = output.appendingPathComponent("Restore")
        try bytes.write(to: conflict)
        try await service.restore(
            repositoryID: repository.id, snapshotID: snapshot.id, components: [], destination: selection(output))
        try await completed(service)
        let restoredState = try #require(try await service.state().restore)
        #expect(restoredState.phase == .succeeded)
        let restored = URL(fileURLWithPath: try #require(restoredState.destination))
        let restoredFile = restored.appendingPathComponent("nested/Überblick + #.txt")
        #expect(SHA256.hash(data: try Data(contentsOf: restoredFile)) == SHA256.hash(data: bytes))
        #expect(try Data(contentsOf: conflict) == bytes)
        #expect(try Data(contentsOf: restored.appendingPathComponent("empty")).isEmpty)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: restored.appendingPathComponent("link").path)
                == "nested/Überblick + #.txt")
        let attributes = try FileManager.default.attributesOfItem(atPath: restoredFile.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 == 1_700_000_000)
        // The underlying REST contract also rejects a nonempty target without changing its data.
        try await service.withRestoreSession(repositoryID: repository.id, destination: nil) { client in
            let conflictTask = try await client.startRestore(root: snapshot.id, destination: restored.path)
            let taskID = try #require(conflictTask.id)
            try await waitForRuntime(timeout: .seconds(10)) {
                let status = try await client.task(id: taskID).status
                return status != "RUNNING" && status != "PENDING"
            }
            #expect(try await client.task(id: taskID).status == "FAILED")
        }
        #expect(try Data(contentsOf: restoredFile) == bytes)
        try await service.previewRestore(
            repositoryID: repository.id, snapshotID: snapshot.id, components: ["nested", "Überblick + #.txt"])
        try await completed(service)
        let preview = try #require(try await service.state().restore)
        #expect(preview.phase == .succeeded)
        let previewPath = try #require(preview.destination)
        #expect(try Data(contentsOf: URL(fileURLWithPath: previewPath)) == bytes)
        try await service.clearRestorePreview()
        #expect(!FileManager.default.fileExists(atPath: previewPath))
        // Cancellation joins the admitted operation before another repository operation can begin.
        try await service.restore(
            repositoryID: repository.id, snapshotID: snapshot.id, components: [], destination: selection(output))
        let operation = try #require(try await service.state().restore?.operationID)
        try await service.cancelRestore(operation)
        #expect(try await service.state().restore?.phase == .cancelled)
        try await service.browse(repositoryID: repository.id, snapshotID: snapshot.id, components: [])
        #expect(try await service.state().restore?.entries.contains(where: { $0.name == "nested" }) == true)
        let safety = try await service.withRestoreSession(repositoryID: repository.id, destination: nil) { service in
            try await service.pinSnapshot(id: snapshot.id)
        }
        let safetyID = try #require(safety.id)
        try await service.editSnapshot(
            repositoryID: repository.id, snapshotID: safetyID, description: "Recovery copy", pinned: true)
        let pinned = try #require(
            try await service.state().restore?.snapshots.first { $0.description == "Recovery copy" })
        #expect(pinned.id != safetyID)
        #expect(pinned.pins.contains("mackopia-user"))
        #expect(pinned.pins.contains("mackopia-plausibility"))
        try await service.editSnapshot(
            repositoryID: repository.id, snapshotID: pinned.id, description: "Recovery copy", pinned: false)
        let unpinned = try #require(
            try await service.state().restore?.snapshots.first { $0.description == "Recovery copy" })
        #expect(!unpinned.pins.contains("mackopia-user"))
        #expect(unpinned.pins.contains("mackopia-plausibility"))
        await #expect(throws: LocalServiceIssue.invalidRequest) {
            try await service.browse(
                repositoryID: repository.id, snapshotID: String(repeating: "f", count: 32), components: [])
        }
        await service.shutdown()
        let files = try #require(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]))
        while let file = files.nextObject() as? URL {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true, values.isSymbolicLink != true {
                #expect(try Data(contentsOf: file).range(of: Data(password.utf8)) == nil)
            }
        }
    }
    private func selection(_ url: URL) throws -> BackupSource {
        try BackupSource(
            path: url.path,
            volume: VolumeIdentity(
                uuid: #require(url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString),
                name: "Temporary", isRemovable: false, isNetwork: false))
    }
    private func completed(_ service: LocalBackupService) async throws {
        try await waitForRuntime(timeout: .seconds(45)) { try await service.state().restore?.phase != .running }
    }
}

private struct RestoreTemporaryAccess: SourceAccessChecking {
    let root: URL
    func checkAccess(to sources: [BackupSource]) throws -> PreflightAccessStatus {
        sources.allSatisfy { $0.path.hasPrefix(root.path + "/") } ? .verified : .denied
    }
}
