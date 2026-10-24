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
            user: "test-user", secrets: secrets), history: history)
    let result = try #require(try await engine.verify(planID: plan.id, filesPercent: 100))
    #expect(result.outcome == .succeeded)
    let reopened = try HistoryStore(directory: root.appendingPathComponent("history"))
    #expect(
        try await reopened.latestVerification(
            planID: plan.id, repositoryID: repository.id, kind: .snapshotVerify, before: .now) == result)
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
}
