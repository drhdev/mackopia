import BackupDomain
import Foundation
import Secrets
import Testing

@testable import BackupEngine
@testable import KopiaCLI

@Suite(
    "Local service with pinned Kopia", .tags(.integration),
    .enabled(if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)))
struct LocalServiceIntegrationTests {
    @Test func createRunReconnectAndRestoreKeepSecretsOutOfDisk() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        let source = root.appendingPathComponent("source")
        for folder in [destination, source] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let bytes = Data(UUID().uuidString.utf8)
        try bytes.write(to: source.appendingPathComponent("sample.txt"))
        let secrets = ServiceTestSecrets()
        let time = SchedulerTestClock(date: .now)
        let service = try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: secrets, sourceAccess: ServiceTemporaryAccess(root: root),
            protection: LocalBackupOperationProtection(), monitor: RuntimeMonitor(),
            runtimeClock: ServiceClock(time), now: { time.date }, loginDate: time.date)
        try await service.start()
        let password = UUID().uuidString
        try await service.setup(
            name: "Disposable", destination: try selection(destination), source: try selection(source),
            password: password, create: true)
        let state = try await service.state()
        let plan = try #require(state.configuration?.plans.first)
        let repository = try #require(state.configuration?.repositories.first)
        #expect(await secrets.read(repository.secretRef)?.data == Data(password.utf8))
        // Repeated create cannot overwrite an existing destination.
        await #expect(throws: LocalServiceIssue.destination) {
            try await service.setup(
                name: "Duplicate", destination: try selection(destination), source: try selection(source),
                password: password, create: true)
        }
        try await service.run(plan.id)
        let completed = try await withThrowingTaskGroup(of: LocalServiceState.self) { group in
            group.addTask {
                var snapshot = try await service.state()
                while snapshot.activePlanID != nil { snapshot = try await service.state(after: snapshot.revision) }
                return snapshot
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45)); throw LocalServiceIssue.unavailable
            }
            defer { group.cancelAll() }
            return try #require(try await group.next())
        }
        let run = try #require(completed.runs.first)
        #expect(run.outcome == .succeeded)
        #expect(completed.plans.first?.verification?.outcome == .succeeded)
        #expect(completed.plans.first?.verification?.filesPercent == 10)
        #expect(completed.plans.first?.testRestore?.outcome == .succeeded)
        #expect(completed.plans.first?.health.severity == .ok)
        // Persist a real time trigger through the same editor/service boundary, then advance
        // the injected monotonic clock. No separate performNext or test-only engine is invoked.
        let automatic = try BackupPlan(
            id: plan.id, name: plan.name, isEnabled: true,
            repositoryID: plan.repositoryID, sources: plan.sources, triggers: [.interval(minutes: 1)],
            conditions: plan.conditions, retention: plan.retention, excludes: plan.excludes,
            options: plan.options, health: plan.health)
        try await service.savePlan(automatic)
        let next = try #require(try await service.state().plans.first?.nextRun)
        time.advance(next.timeIntervalSince(time.date) + 1)
        try await waitForRuntime(timeout: .seconds(45)) {
            let value = try await service.state()
            return value.runs.count == 2 && value.activePlanID == nil
        }
        let scheduled = try await service.state()
        #expect(scheduled.runs.first?.outcome == .succeeded)
        #expect(scheduled.runs.first?.trigger == .interval(minutes: 1))
        // Explicit checks also use the owner's serial drain, and keep their durable evidence.
        try await service.verify(plan.id)
        try await waitForRuntime(timeout: .seconds(45)) { try await service.state().activePlanID == nil }
        #expect(try await service.state().plans.first?.verification?.filesPercent == 1)
        let snapshot = try #require(run.sources.first)
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: root)
        let context = KopiaExecutionContext(
            executable: NativeKopiaFixture.binary, paths: paths, temporaryDirectory: root,
            user: NSUserName(), configuration: .file, backupPassword: password)
        let restore = root.appendingPathComponent("restored")
        #expect(
            try await KopiaProcess().run(
                context.request(for: .restoreSample(objectID: snapshot.rootID, destination: restore.path))
            ).exitCode == 0)
        #expect(try Data(contentsOf: restore.appendingPathComponent("sample.txt")) == bytes)
        let secondSource = root.appendingPathComponent("second-source")
        try FileManager.default.createDirectory(at: secondSource, withIntermediateDirectories: false)
        try bytes.write(to: secondSource.appendingPathComponent("sample.txt"))
        try await service.createPlan(name: "Second", repositoryID: repository.id, source: selection(secondSource))
        let added = try #require(try await service.state().configuration?.plans.last)
        #expect(added.name == "Second")
        let edited = try BackupPlan(
            id: added.id, name: "Edited", isEnabled: false, repositoryID: added.repositoryID,
            sources: added.sources, triggers: added.triggers, conditions: added.conditions, retention: added.retention,
            excludes: added.excludes, options: added.options, health: added.health)
        try await service.savePlan(edited)
        let final = try await service.state()
        #expect(final.configuration?.plans.last == edited)
        await service.shutdown()
        let reopened = try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: secrets, sourceAccess: ServiceTemporaryAccess(root: root),
            protection: ManualTestProtection(), monitor: RuntimeMonitor(),
            runtimeClock: ServiceClock(time), now: { time.date }, loginDate: time.date)
        try await reopened.start()
        let reconnected = try await reopened.state()
        #expect(reconnected.configuration == final.configuration)
        #expect(reconnected.runs.count == 2)
        #expect(reconnected.runs.last == run)
        await reopened.shutdown()
        let connectingHome = root.appendingPathComponent("connecting-home")
        let connecting = try LocalBackupService(
            executable: NativeKopiaFixture.binary, home: connectingHome, temporary: root,
            expectedVersion: "0.23.1", secrets: secrets, sourceAccess: ServiceTemporaryAccess(root: root),
            protection: LocalBackupOperationProtection())
        try await connecting.start()
        try await connecting.setup(
            name: "Connected", destination: selection(destination), source: selection(source), password: password,
            create: false)
        #expect(try await connecting.state().configuration?.plans.count == 1)
        await connecting.shutdown()
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        while let file = enumerator.nextObject() as? URL {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                #expect(try Data(contentsOf: file).range(of: Data(password.utf8)) == nil)
            }
        }
    }

    private func selection(_ url: URL) throws -> BackupSource {
        let uuid = try #require(url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        return try BackupSource(
            path: url.path, volume: VolumeIdentity(uuid: uuid, name: "Temporary", isRemovable: false, isNetwork: false))
    }

    @Test func protectedChildProbeReadsOnlyBoundedFileWithoutRepositoryOrContentLogs() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Library/Safari")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Bookmarks.plist")
        let probe = KopiaProtectedFileProbe(executable: NativeKopiaFixture.binary, home: root, temporary: root)
        let marker = UUID().uuidString
        try Data(marker.utf8).write(to: file)
        #expect(try await probe.canReadProtectedFile())
        try Data().write(to: file)
        #expect(try await !probe.canReadProtectedFile())
        try Data(count: 1_048_577).write(to: file)
        #expect(try await !probe.canReadProtectedFile())
        try FileManager.default.removeItem(at: file)
        await #expect(throws: (any Error).self) { try await probe.canReadProtectedFile() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Logs").path))
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("Library/Application Support").path))
    }
}

private struct ServiceTemporaryAccess: SourceAccessChecking {
    let root: URL
    func checkAccess(to sources: [BackupSource]) throws -> PreflightAccessStatus {
        guard !sources.isEmpty, sources.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) else { return .denied }
        for source in sources {
            _ = try Data(contentsOf: URL(fileURLWithPath: source.path).appendingPathComponent("sample.txt"))
        }
        return .verified
    }
}
