import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Secrets
import Testing

/// Uses the manual engine's real temporary repositories and shared operation gate.
func verifyLatestIntegrationBackup(
    plan: BackupPlan, repository: Repository, store: ConfigStore, preflight: BackupPreflight,
    history: HistoryStore, root: URL, secrets: any SecretStore
) async throws {
    let engine = SnapshotVerificationEngine(
        store: store,
        coordinator: BackupOperationCoordinator(preflight: preflight, protection: LocalBackupOperationProtection()),
        verifier: FilesystemSnapshotVerification(
            executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
            user: "test-user", secrets: secrets), history: history,
        restorer: FilesystemTestRestore(
            executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
            user: "test-user", secrets: secrets))
    let result = try #require(try await engine.verify(planID: plan.id, filesPercent: 100))
    #expect(result.outcome == .succeeded)
    #expect(result.filesPercent == 100)
    let restore = try #require(try await engine.testRestore(planID: plan.id))
    #expect(restore.kind == .testRestore && restore.outcome == .succeeded)
    #expect(restore.filesPercent == nil)
    #expect(restore.dueAt.timeIntervalSince(restore.endedAt) == 30 * 24 * 60 * 60)
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
            !$0.hasPrefix("mackopia-test-restore-")
        })
    let reopened = try HistoryStore(directory: root.appendingPathComponent("history"))
    #expect(
        try await reopened.latestVerification(
            planID: plan.id, repositoryID: repository.id, kind: .snapshotVerify, before: .now) == result)
    #expect(
        try await reopened.latestVerification(
            planID: plan.id, repositoryID: repository.id, kind: .testRestore, before: .now) == restore)
    #expect(
        try await reopened.latestVerification(
            planID: plan.id, repositoryID: repository.id, kind: .snapshotVerify,
            before: .now, minimumFilesPercent: 10) == result)
    let automatic = AutomaticBackupRuntime(
        store: store,
        coordinator: BackupOperationCoordinator(preflight: preflight, protection: LocalBackupOperationProtection()),
        sessions: FilesystemBackupSessions(
            executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
            user: "test-user", secrets: secrets),
        history: reopened, resolver: try TimeMachineExclusionResolver(), homeDirectory: root.path,
        loginDate: .now, clock: ContinuousClock(), monitor: RuntimeMonitor(),
        issue: { _ in Issue.record("Unexpected automatic runtime issue during read-only health query") })
    #expect(try await automatic.health(planID: plan.id).severity == .ok)
    let maintenance = MaintenanceCoordinator(
        store: store,
        coordinator: BackupOperationCoordinator(preflight: preflight, protection: LocalBackupOperationProtection()),
        inspector: FilesystemMaintenanceInspection(
            executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
            user: "test-user", secrets: secrets))
    // Read the real pinned CLI response under the backup's shared gate; never run maintenance here.
    let observation = try #require(try await maintenance.inspect(planID: plan.id))
    switch observation {
    case .due, .scheduled: break
    default: Issue.record("The temporary repository must retain its own enabled maintenance owner")
    }
}

/// Only called for a freshly created disposable repository before its first server starts.
func maintainFreshIntegrationRepository(
    plan: BackupPlan, repository: Repository, store: ConfigStore, preflight: BackupPreflight,
    root: URL, secrets: any SecretStore
) async throws {
    let adapter = FilesystemMaintenanceInspection(
        executable: NativeKopiaFixture.binary, homeDirectory: root, temporaryDirectory: root,
        user: "test-user", secrets: secrets)
    let maintenance = MaintenanceCoordinator(
        store: store,
        coordinator: BackupOperationCoordinator(preflight: preflight, protection: LocalBackupOperationProtection()),
        inspector: adapter, runner: adapter)
    #expect(try await maintenance.inspect(planID: plan.id) == .due)
    #expect(try await maintenance.runDueFull(planID: plan.id) == .completed)
    let observation = try #require(try await maintenance.inspect(planID: plan.id))
    guard case .scheduled(let date) = observation else {
        Issue.record("Successful full maintenance must advance the disposable repository's schedule")
        return
    }
    #expect(date > .now)
    #expect(try await maintenance.runDueFull(planID: plan.id) == .skipped(.scheduled(date)))
}
