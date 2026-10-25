import BackupDomain
import BackupEngine
import Foundation
import KopiaServer
import Persistence
import Secrets
import SystemIntegration
import Testing

@testable import KopiaCLI

@Suite(
    "Manual engine with real pinned Kopia", .tags(.integration),
    .enabled(
        if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)
            || ProcessInfo.processInfo.environment["MACKOPIA_REQUIRE_KOPIA_INTEGRATION"] == "1"))
struct ManualBackupIntegrationTests {
    @Test func twoNewSourcesProduceDurableHistoryAndByteIdenticalRestores() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("storage")
        let repositoryID = UUID()
        let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let volumeUUID = try #require(root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
        let volume = try VolumeIdentity(uuid: volumeUUID, name: "Temporary", isRemovable: false, isNetwork: false)
        let repository = try Repository(
            id: repositoryID, name: "Disposable", kind: .filesystem(path: destination.path, volume: volume),
            identity: SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host"), secretRef: SecretRef())
        let password = UUID().uuidString
        let context = KopiaExecutionContext(
            executable: NativeKopiaFixture.binary, paths: paths,
            temporaryDirectory: root, user: "test-user", configuration: .file, backupPassword: password)
        let environment = context.request(for: .repositoryStatus).environment
        let arguments = [
            "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path,
            "--log-dir=" + paths.logDirectory.path, "--no-progress", "--no-use-keychain", "--no-persist-credentials",
        ]
        let create = KopiaProcessRequest(
            executable: NativeKopiaFixture.binary,
            arguments: arguments + [
                "repository", "create", "filesystem", "--path=" + destination.path,
                "--cache-directory=" + paths.cacheDirectory.path, "--override-username=test-user",
                "--override-hostname=test-host", "--no-check-for-updates",
            ], environment: environment)
        #expect(try await KopiaProcess().run(create).exitCode == 0)
        let sources = try ["Quelle ü + & ? # %2F", "Second"].map { name -> BackupSource in
            let directory = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data(("unique content " + name).utf8).write(to: directory.appendingPathComponent("data.txt"))
            try Data().write(to: directory.appendingPathComponent("empty"))
            return try BackupSource(path: directory.path, volume: volume)
        }
        let plan = try BackupPlan(
            name: "Two sources", isEnabled: true, repositoryID: repositoryID,
            sources: sources, triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false,
                skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: false, honorTimeMachineExclusions: false, ignoreCacheDirs: false),
            options: PlanOptions(lowPriority: false, ejectVolumeAfterBackup: false), health: HealthThresholds())
        let store = try ConfigStore(directory: root.appendingPathComponent("settings"))
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [repository], plans: [plan]))
        let historyDirectory = root.appendingPathComponent("history")
        let history = try HistoryStore(directory: historyDirectory)
        let access = TemporaryBackupAccess(root: root, password: password)
        let verifier = try KopiaBinaryVerifier(
            executable: NativeKopiaFixture.binary, paths: paths,
            temporaryDirectory: root, expectedVersion: try #require(NativeKopiaFixture.pin).version)
        let preflight = BackupPreflight(
            prerequisites: BackupPrerequisitePreflight(binary: verifier, secrets: access),
            gate: try RepositoryOperationGate(), sourceAccess: access, environment: access)
        try KopiaFilesystemBinding.validate(repository: repository, homeDirectory: root)
        #expect(try await preflight.evaluate(plan: plan, repository: repository).outcome == .checksPassed)
        try await maintainFreshIntegrationRepository(
            plan: plan, repository: repository, store: store, preflight: preflight, root: root, secrets: access)
        let stages = IntegrationStages()
        let engine = ManualBackupEngine(
            runner: ConfiguredJobRunner(
                store: store, queue: JobQueue(),
                coordinator: BackupOperationCoordinator(
                    preflight: preflight, protection: LocalBackupOperationProtection())),
            sessions: FilesystemBackupSessions(
                executable: NativeKopiaFixture.binary, homeDirectory: root,
                temporaryDirectory: root, user: "test-user", secrets: access), history: history,
            resolver: try TimeMachineExclusionResolver(), homeDirectory: root.path,
            stageChanged: { await stages.record($0) })
        for index in 0..<2 {
            _ = try await engine.enqueue(planID: plan.id)
            let run: JobRun
            do { run = try #require(try await engine.performNext()) } catch {
                Issue.record("Engine failed during stage: \(String(describing: await stages.last))")
                throw error
            }
            #expect(run.outcome == .succeeded)
            #expect(run.sources.count == 2)
            #expect(run.sources.map(\.sourceID) == sources.map(\.id))
            for result in run.sources {
                let original = try #require(sources.first { $0.id == result.sourceID })
                let restore = root.appendingPathComponent("restored-\(index)-" + result.sourceID.uuidString)
                let request = KopiaProcessRequest(
                    executable: NativeKopiaFixture.binary,
                    arguments: arguments + [
                        "snapshot", "restore", result.rootID, restore.path, "--no-overwrite-files",
                        "--no-overwrite-directories", "--no-overwrite-symlinks",
                    ], environment: environment)
                #expect(try await KopiaProcess().run(request).exitCode == 0)
                #expect(
                    try Data(contentsOf: restore.appendingPathComponent("data.txt"))
                        == Data(
                            contentsOf:
                                URL(fileURLWithPath: original.path).appendingPathComponent("data.txt")))
                #expect(try Data(contentsOf: restore.appendingPathComponent("empty")).isEmpty)
                #expect(result.files == 2)
            }
        }
        try await verifyLatestIntegrationBackup(
            plan: plan, repository: repository, store: store, preflight: preflight,
            history: history, root: root, secrets: access)
        let recoveryClock = SchedulerTestClock(date: .now)
        let abandonedID = UUID()
        try await history.begin(
            JobRun(
                id: abandonedID, planID: plan.id, repositoryID: repositoryID, trigger: .manual,
                startedAt: recoveryClock.date, endedAt: recoveryClock.date, outcome: .running, sources: [], issues: []))
        let controlState = store.pauseStore.makeSession()
        _ = try controlState.load()
        try controlState.saveWork([
            StoredBackupWork(
                id: abandonedID, planID: plan.id, repositoryID: repositoryID, trigger: .manual,
                requestedAt: recoveryClock.date, state: .active)
        ])
        let automatic = AutomaticBackupRuntime(
            store: store,
            coordinator: BackupOperationCoordinator(preflight: preflight, protection: LocalBackupOperationProtection()),
            sessions: FilesystemBackupSessions(
                executable: NativeKopiaFixture.binary, homeDirectory: root,
                temporaryDirectory: root, user: "test-user", secrets: access),
            history: history, resolver: try TimeMachineExclusionResolver(), homeDirectory: root.path,
            loginDate: recoveryClock.date, clock: recoveryClock, now: { recoveryClock.date }, monitor: RuntimeMonitor(),
            issue: { _ in Issue.record("Automatic drain unexpectedly reported a failure") })
        try await automatic.start()
        try await waitForRuntime { recoveryClock.sleeperCount == 1 }
        recoveryClock.advance(120)
        try await waitForRuntime(timeout: .seconds(30)) {
            recoveryClock.advance(1)
            return (try? await history.recent().filter { $0.outcome == .succeeded }.count) == 3
        }
        await automatic.shutdown()
        #expect(await automatic.state == .stopped)
        let automaticRuns = try await history.recent()
        #expect(automaticRuns.count == 4)
        #expect(automaticRuns.filter { $0.outcome == .succeeded && $0.sources.count == 2 }.count == 3)
        #expect(automaticRuns.first { $0.id == abandonedID }?.issues == [.processInterrupted])
        #expect(automaticRuns.first { $0.id == abandonedID }?.outcome == .cancelled)
        _ = try controlState.load()
        #expect(try controlState.loadWork().isEmpty)
        // Generated source content only: a >50% size drop must protect the new manifests.
        for source in sources {
            try Data().write(to: URL(fileURLWithPath: source.path).appendingPathComponent("data.txt"))
        }
        _ = try await engine.enqueue(planID: plan.id)
        let suspicious = try #require(try await engine.performNext())
        #expect(suspicious.outcome == .succeededWithWarnings)
        #expect(suspicious.issues == [.suspiciousSnapshot])
        #expect(suspicious.sources.allSatisfy { $0.bytes == 0 && $0.files == 2 })
        let inspection = try await FilesystemBackupSessions(
            executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
            user: "test-user", secrets: access
        ).open(repository: repository, options: plan.options)
        do {
            for result in suspicious.sources {
                let source = try #require(sources.first { $0.id == result.sourceID })
                let selector = try KopiaSnapshotSource(userName: "test-user", host: "test-host", path: source.path)
                let snapshots = try #require(try await inspection.service.snapshotManifests(source: selector).snapshots)
                let pinned = try #require(snapshots.first { $0.id == result.snapshotID })
                #expect(pinned.rootID == result.rootID)
                #expect(pinned.pins?.contains(KopiaServerClient.plausibilityPin) == true)
                let restored = root.appendingPathComponent("restored-pinned-" + result.sourceID.uuidString)
                let request = KopiaProcessRequest(
                    executable: NativeKopiaFixture.binary,
                    arguments: arguments + [
                        "snapshot", "restore", result.snapshotID, restored.path,
                        "--no-overwrite-files", "--no-overwrite-directories", "--no-overwrite-symlinks",
                    ],
                    environment: environment)
                #expect(try await KopiaProcess().run(request).exitCode == 0)
                #expect(try Data(contentsOf: restored.appendingPathComponent("data.txt")).isEmpty)
            }
            try await inspection.close()
        } catch {
            try? await inspection.close()
            throw error
        }
        let cancellation = CancellationSessionObservation()
        let cancelQueue = JobQueue()
        let cancelledEngine = ManualBackupEngine(
            runner: ConfiguredJobRunner(
                store: store, queue: cancelQueue,
                coordinator: BackupOperationCoordinator(
                    preflight: preflight, protection: LocalBackupOperationProtection())),
            sessions: CancelAfterUploadSessions(
                base: FilesystemBackupSessions(
                    executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
                    user: "test-user", secrets: access), observation: cancellation),
            history: history, resolver: try TimeMachineExclusionResolver(), homeDirectory: root.path)
        _ = try await cancelledEngine.enqueue(planID: plan.id)
        let cancelled = Task { try await cancelledEngine.performNext() }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await cancellation.closed)
        #expect(await cancellation.uploads == 1)
        #expect(await cancellation.cancellations == 1)
        _ = try await cancelledEngine.enqueue(planID: plan.id)
        #expect(await cancelQueue.takeNext() != nil)
        let reopened = try HistoryStore(directory: historyDirectory)
        let runs = try await reopened.recent()
        #expect(runs.count == 6)
        #expect(runs.filter { $0.outcome == .succeeded && $0.sources.count == 2 }.count == 3)
        #expect(runs.filter { $0.outcome == .cancelled }.count == 2)
        #expect(runs.first { $0.id == suspicious.id } == suspicious)
        #expect(Set(runs.flatMap(\.sources).map(\.snapshotID)).count == 8)
        try assertNoPassword(root: root, password: password)
    }

    private func assertNoPassword(root: URL, password: String) throws {
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                #expect(try Data(contentsOf: file).range(of: Data(password.utf8)) == nil)
            }
        }
    }
}

/// Test-only authorization confined to generated temporary sources. Production FDA stays fail-closed.
private struct TemporaryBackupAccess: SecretStore, SourceAccessChecking, RunEnvironmentSampling {
    let root: URL
    let password: String
    func read(_ reference: SecretRef) throws -> SecretValue? { try SecretValue(data: Data(password.utf8)) }
    func write(_ value: SecretValue, for reference: SecretRef) { Issue.record("Unexpected write") }
    func delete(_ reference: SecretRef) { Issue.record("Unexpected delete") }
    func checkAccess(to sources: [BackupSource]) throws -> PreflightAccessStatus {
        guard sources.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) else { return .denied }
        for source in sources {
            _ = try Data(contentsOf: URL(fileURLWithPath: source.path).appendingPathComponent("data.txt"))
        }
        return .verified
    }
    func sample() throws -> RunEnvironment { try RunEnvironment(isOnACPower: true) }
}

private actor IntegrationStages {
    var last: ManualBackupStage?
    func record(_ stage: ManualBackupStage) { last = stage }
}
