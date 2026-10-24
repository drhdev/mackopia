import BackupDomain
import Foundation
import SystemIntegration
import Testing

@testable import BackupEngine

struct TriggerFixture: Sendable {
    let source: VolumeIdentity
    let destination: VolumeIdentity
    let repository: Repository
    let backup: BackupPlan
    let configuration: BackupConfiguration

    init(remote: Bool = false) throws {
        source = try VolumeIdentity(uuid: UUID().uuidString, name: "Source", isRemovable: true, isNetwork: false)
        destination = try VolumeIdentity(
            uuid: UUID().uuidString, name: "Destination", isRemovable: true, isNetwork: false)
        repository = try Repository(
            name: "Test",
            kind: remote
                ? .webdav(url: #require(URL(string: "https://backup.invalid")))
                : .filesystem(path: "/Destination", volume: destination),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test-host"), secretRef: SecretRef())
        backup = try Self.makePlan(
            repository: repository, source: source, triggers: remote ? [.onNetworkReachable] : [.onVolumeMount])
        configuration = try BackupConfiguration(repositories: [repository], plans: [backup])
    }

    func plan(
        triggers: [Trigger] = [.onVolumeMount], enabled: Bool = true, conditions: RunConditions? = nil
    ) throws -> BackupPlan {
        try Self.makePlan(
            repository: repository, source: source, triggers: triggers, enabled: enabled, conditions: conditions)
    }

    private static func makePlan(
        repository: Repository, source: VolumeIdentity, triggers: [Trigger], enabled: Bool = true,
        conditions: RunConditions? = nil
    ) throws -> BackupPlan {
        let id = UUID()
        return try BackupPlan(
            id: id, name: "Test", isEnabled: enabled, repositoryID: repository.id,
            sources: [BackupSource(path: "/Source-" + id.uuidString, volume: source)], triggers: triggers,
            conditions: conditions
                ?? RunConditions(
                    requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: true),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: false, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }
}

actor TriggerAdmissions {
    private(set) var requests: [ScheduledRequest] = []
    private(set) var failures = 0
    func append(_ request: ScheduledRequest) { requests.append(request) }
    func failed() { failures += 1 }
}

actor TriggerReachability: DestinationReachabilityChecking {
    enum Mode { case allow, deny, waitForCancellation, lateSuccess, heldSuccess }
    let mode: Mode
    private var held: CheckedContinuation<Bool, Never>?
    private(set) var targets: [ReachabilityTarget] = []
    private(set) var cleaned = 0
    init(mode: Mode = .allow) { self.mode = mode }
    func canConnect(to target: ReachabilityTarget) async throws -> Bool {
        targets.append(target)
        if mode == .heldSuccess { return await withCheckedContinuation { held = $0 } }
        if mode == .waitForCancellation || mode == .lateSuccess {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cleaned += 1
                if mode == .lateSuccess { return true }
                throw error
            }
        }
        return mode != .deny
    }
    func succeed() { held?.resume(returning: true); held = nil }
}

actor TriggerCoordinatorHolder {
    private var coordinator: EventTriggerCoordinator<SchedulerTestClock>?
    func set(_ coordinator: EventTriggerCoordinator<SchedulerTestClock>) { self.coordinator = coordinator }
    func stop() async { await coordinator?.stop(); coordinator = nil }
}
