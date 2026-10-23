import BackupDomain
import BackupEngine
import Foundation
import KopiaCLI
import Secrets
import SystemIntegration
import Testing

struct PreflightTestScenario: Sendable {
    var missingPassword = false
    var failAt: String?
    var cancelAt: String?
    var missingSources: Set<String> = []
    var sourceAccess: PreflightAccessStatus = .verified
    var repositoryAccess: PreflightAccessStatus = .verified
    var availableBytes: Int64 = 10_000_000_000
    var expensiveNetwork = false
}

struct PreflightTestFixture: Sendable {
    let repository: Repository
    let plan: BackupPlan
    let probe: PreflightTestProbe
    let preflight: BackupPreflight

    init(
        scenario: PreflightTestScenario = .init(), remote: Bool = false,
        gate: RepositoryOperationGate? = nil, useUnknownAdapters: Bool = false
    ) throws {
        let volume = try VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: true, isNetwork: false)
        let remoteURL = try #require(URL(string: "https://example.invalid"))
        repository = try Repository(
            name: "Test", kind: remote ? .webdav(url: remoteURL) : .filesystem(path: "/Destination", volume: volume),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test-host"), secretRef: SecretRef())
        plan = try BackupPlan(
            name: "Test", isEnabled: true, repositoryID: repository.id,
            sources: [BackupSource(path: "/Source", volume: volume), BackupSource(path: "/Other", volume: volume)],
            triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: false, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
        probe = PreflightTestProbe(volume: volume, scenario: scenario)
        let reservation = try gate ?? RepositoryOperationGate()
        preflight = BackupPreflight(
            prerequisites: BackupPrerequisitePreflight(binary: probe, secrets: probe), gate: reservation,
            paths: BackupPathPreflight(inspector: probe), destination: FilesystemDestinationPreflight(inspector: probe),
            repositoryAccess: useUnknownAdapters ? UnknownPreflightObservations() : probe,
            sourceAccess: useUnknownAdapters ? UnknownPreflightObservations() : probe,
            environment: useUnknownAdapters ? UnknownPreflightObservations() : probe)
    }
}

actor PreflightTestProbe: KopiaBinaryVerifying, SecretStore, DirectoryInspecting,
    FilesystemDestinationInspecting, RepositoryAccessChecking, SourceAccessChecking, RunEnvironmentSampling
{
    let volume: VolumeIdentity
    private var scenario: PreflightTestScenario
    private(set) var operations: [String] = []
    private(set) var accessSourceIDs: [UUID] = []

    init(volume: VolumeIdentity, scenario: PreflightTestScenario) {
        self.volume = volume
        self.scenario = scenario
    }

    func updateScenario(_ scenario: PreflightTestScenario) { self.scenario = scenario }

    func verify() async throws { try record("binary") }
    func read(_ reference: SecretRef) async throws -> SecretValue? {
        try record("secret")
        return scenario.missingPassword ? nil : try SecretValue(data: Data([1]))
    }
    func write(_ value: SecretValue, for reference: SecretRef) async throws { Issue.record("Unexpected secret write") }
    func delete(_ reference: SecretRef) async throws { Issue.record("Unexpected secret delete") }

    func inspectDirectory(at path: String) async throws -> DirectoryObservation {
        try record("directory:" + path)
        if scenario.missingSources.contains(path) { throw VolumeInspectionError.unavailable }
        return try DirectoryObservation(canonicalPath: path, volumeUUID: volume.uuid, isCaseSensitive: true)
    }

    func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation {
        try record("filesystem")
        return try FilesystemDestinationObservation(
            volumeUUID: volume.uuid, isWritable: true, availableBytes: scenario.availableBytes,
            totalBytes: 100_000_000_000)
    }

    func checkAccess(to repository: Repository) async throws -> PreflightAccessStatus {
        try record("remote")
        return scenario.repositoryAccess
    }

    func checkAccess(to sources: [BackupSource]) async throws -> PreflightAccessStatus {
        try record("sourceAccess")
        accessSourceIDs = sources.map(\.id)
        return scenario.sourceAccess
    }

    func sample() async throws -> RunEnvironment {
        try record("environment")
        return try RunEnvironment(isExpensiveNetwork: scenario.expensiveNetwork)
    }

    private func record(_ operation: String) throws {
        operations.append(operation)
        if scenario.cancelAt == operation { withUnsafeCurrentTask { $0?.cancel() } }
        if scenario.failAt == operation { throw NSError(domain: "private-marker", code: 1) }
    }
}
