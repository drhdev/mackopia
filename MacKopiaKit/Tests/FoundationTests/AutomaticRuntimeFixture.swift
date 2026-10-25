import BackupDomain
import BackupEngine
import Foundation
import KopiaServer
import Persistence
import SystemIntegration
import Testing

@testable import Persistence

struct AutomaticRuntimeFixture: Sendable {
    let base: PreflightTestFixture
    let time = SchedulerTestClock()
    let monitor = RuntimeMonitor()
    let sessions: RuntimeSessions
    let history = RuntimeHistory()
    let issues = RuntimeIssues()
    let files = MemoryConfigFiles()
    let store: ConfigStore
    let plan: BackupPlan

    init(
        triggers: [Trigger] = [.interval(minutes: 1), .onVolumeMount], mode: RuntimeSessions.Mode = .normal,
        sourceAccess: PreflightAccessStatus = .verified
    ) async throws {
        base = try PreflightTestFixture(scenario: PreflightTestScenario(sourceAccess: sourceAccess))
        let original = base.plan
        plan = try BackupPlan(
            id: original.id, name: original.name, isEnabled: true, repositoryID: original.repositoryID,
            sources: original.sources, triggers: triggers, conditions: original.conditions,
            retention: original.retention,
            excludes: original.excludes, options: original.options, health: original.health)
        sessions = RuntimeSessions(mode: mode)
        store = ConfigStore(files: files, codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [base.repository], plans: [plan]))
    }

    func runtime(
        historyOverride: (any JobHistoryRecording)? = nil,
        monitorOverride: (any SystemEventMonitoring)? = nil,
        verification: AutomaticSnapshotVerification? = nil,
        testRestore: AutomaticTestRestore? = nil,
        coordinator: BackupOperationCoordinator? = nil,
        issue: (@Sendable (AutomaticBackupIssue) async -> Void)? = nil
    ) throws -> AutomaticBackupRuntime<SchedulerTestClock> {
        AutomaticBackupRuntime(
            store: store,
            coordinator: coordinator
                ?? BackupOperationCoordinator(preflight: base.preflight, protection: ManualTestProtection()),
            sessions: sessions, history: historyOverride ?? history, resolver: try TimeMachineExclusionResolver(),
            homeDirectory: "/Home",
            loginDate: time.date, clock: time, now: { time.date }, monitor: monitorOverride ?? monitor,
            reachability: RuntimeReachability(), jitter: { 0 }, verification: verification, testRestore: testRestore,
            issue: issue ?? { await issues.record($0) })
    }
}

actor RuntimeSessions: BackupSessionOpening {
    enum Mode: Sendable { case normal, firstWaits, alwaysTransient, permanentFailure, validIdentifiers }
    let mode: Mode
    var services: [ManualBackupService] = []
    var opens = 0
    init(mode: Mode) { self.mode = mode }
    func open(repository: Repository, options: PlanOptions) async throws -> KopiaBackupSession {
        opens += 1
        if mode == .alwaysTransient { throw BackupOperationError.volumeDisappeared }
        if mode == .permanentFailure { throw BackupOperationError.operationFailed }
        let service = ManualBackupService(
            mode: mode == .firstWaits && opens == 1 ? .waitForCancellation : .normal,
            validSnapshotIDs: mode == .validIdentifiers)
        services.append(service)
        await service.markOpened()
        return KopiaBackupSession(service: service) { try await service.close() }
    }
}

actor RuntimeHistory: JobHistoryRecording {
    var started: [JobRun] = []
    var finished: [JobRun] = []
    func begin(_ run: JobRun) { started.append(run) }
    func finish(_ run: JobRun) { finished.append(run) }
}

actor RuntimeIssues {
    var values: [AutomaticBackupIssue] = []
    func record(_ issue: AutomaticBackupIssue) { values.append(issue) }
}

/// Controlled stream lifetime, including unexpected termination and cancellation cleanup evidence.
actor RuntimeMonitor: SystemEventMonitoring {
    private let stream: AsyncThrowingStream<SystemEvent, any Error>
    private let continuation: AsyncThrowingStream<SystemEvent, any Error>.Continuation
    var observing = false
    var closed = false
    init() { (stream, continuation) = AsyncThrowingStream.makeStream() }
    func observe(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws {
        observing = true
        defer { closed = true }
        for try await event in stream { try Task.checkCancellation(); await deliver(event) }
    }
    func send(_ event: SystemEvent) { continuation.yield(event) }
    func fail() { continuation.finish(throwing: SystemMonitoringError.unavailable) }
}

private struct RuntimeReachability: DestinationReachabilityChecking {
    func canConnect(to target: ReachabilityTarget) async throws -> Bool { false }
}

func waitForRuntime(timeout: Duration = .seconds(5), _ ready: () async throws -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !(try await ready()) {
        guard clock.now < deadline else { throw RuntimeTestError.timedOut }
        try await clock.sleep(for: .milliseconds(5))
    }
}

private enum RuntimeTestError: Error { case timedOut }
