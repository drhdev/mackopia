import BackupDomain
import Foundation
import Persistence
import SystemIntegration
import Testing

@testable import BackupEngine

struct DailyServiceTests {
    @Test func configuredAutomaticTriggerUsesServiceQueueAndPersistsPausedStateAcrossRestart() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PreflightTestFixture()
        let original = fixture.plan
        let plan = try BackupPlan(
            id: original.id, name: original.name, isEnabled: true,
            repositoryID: original.repositoryID, sources: original.sources, triggers: [.interval(minutes: 1)],
            conditions: original.conditions, retention: original.retention, excludes: original.excludes,
            options: original.options, health: original.health)
        let directory = try LocalServiceStorage.prepare(home: root)
        let store = try ConfigStore(directory: directory)
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [plan]))
        let time = SchedulerTestClock(date: .now)
        let service = try makeService(root, time: time)
        try await service.start()
        let initial = try await service.state()
        #expect(initial.plans.first?.nextRun != nil)
        try await service.pause(planID: plan.id)
        #expect(try await service.state().plans.first?.pause == .indefinite)
        time.advance(180)
        #expect(try await service.state().runs.isEmpty)
        await #expect(throws: LocalServiceIssue.planPaused) { try await service.run(plan.id) }
        try await service.setNotificationsEnabled(true)
        await service.shutdown()
        let restarted = try makeService(root, time: time)
        try await restarted.start()
        #expect(try await restarted.state().plans.first?.pause == .indefinite)
        #expect(try await restarted.state().configuration?.notificationsEnabled == true)
        try await restarted.resume(planID: plan.id)
        let next = try #require(try await restarted.state().plans.first?.nextRun)
        time.advance(max(1, next.timeIntervalSince(time.date) + 1))
        try await waitForRuntime {
            let snapshot = try await restarted.state()
            return snapshot.runs.count == 1 && snapshot.activePlanID == nil
        }
        let state = try await restarted.state()
        #expect(state.runs.first?.trigger == .interval(minutes: 1))
        #expect(state.runs.first?.outcome == .skipped)
        #expect(state.plans.first?.issue == .destination)
        #expect(state.plans.first?.health.severity != .ok)
        await restarted.shutdown()
        #expect(time.sleeperCount == 0)
    }

    @Test func globalPauseLayersWithPlanPauseAndUnknownControlsAreRejected() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = SchedulerTestClock(date: .now)
        let service = try makeService(root, time: time)
        try await service.start()
        try await service.pause(until: time.date.addingTimeInterval(3600))
        #expect(try await service.state().globalPause == .until(time.date.addingTimeInterval(3600)))
        await #expect(throws: DomainValidationError.invalidPlan) { try await service.pause(planID: UUID()) }
        await #expect(throws: LocalServiceIssue.invalidRequest) { try await service.verify(UUID()) }
        try await service.resume()
        #expect(try await service.state().globalPause == nil)
        await service.shutdown()
    }

    @Test func monitorFailureIsVisibleWithoutMakingConfigurationDisappear() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = RuntimeMonitor()
        let service = try makeService(root, time: SchedulerTestClock(date: .now), monitor: monitor)
        try await service.start()
        try await waitForRuntime { await monitor.observing }
        await monitor.fail()
        try await waitForRuntime { try await service.state().issue == .automationUnavailable }
        #expect(try await service.state().configuration != nil)
        await service.shutdown()
    }

    @Test func failedRestoreAndMaintenanceEvidenceRemainVisibleAfterReopen() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try PreflightTestFixture()
        let directory = try LocalServiceStorage.prepare(home: root)
        let store = try ConfigStore(directory: directory)
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [fixture.plan]))
        let time = SchedulerTestClock(date: .now)
        let history = try HistoryStore(directory: directory.appendingPathComponent("History"))
        try await history.recordVerification(
            VerificationResult(
                planID: fixture.plan.id,
                repositoryID: fixture.repository.id, kind: .testRestore, startedAt: time.date,
                endedAt: time.date, dueAt: time.date.addingTimeInterval(86400), outcome: .failed))
        try await history.recordMaintenance(
            MaintenanceResult(
                repositoryID: fixture.repository.id,
                endedAt: time.date, outcome: .failed))
        for _ in 0..<2 {
            let service = try makeService(root, time: time)
            try await service.start()
            let state = try await service.state()
            #expect(state.plans.first?.health.reasons.contains(.testRestoreFailed) == true)
            #expect(state.plans.first?.health.reasons.contains(.maintenanceFailed) == true)
            #expect(state.plans.first?.health.severity == .critical)
            await service.shutdown()
        }
    }

    @Test func restartAfterMonitorFailureStartsAFreshObservationAndPreservesConfiguration() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let time = SchedulerTestClock(date: .now)
        let monitor = RestartableServiceMonitor()
        let service = try makeService(root, time: time, monitor: monitor)
        try await service.start()
        let configuration = try await service.state().configuration
        try await waitForRuntime { await monitor.count == 1 }
        await monitor.fail()
        try await waitForRuntime { try await service.state().issue == .automationUnavailable }
        try await service.restartAutomation()
        try await waitForRuntime { await monitor.count == 2 }
        #expect(try await service.state().issue == nil)
        #expect(try await service.state().configuration == configuration)
        await service.shutdown()
    }

    @Test func startupRemovesAbandonedPreviewButRepeatedStartPreservesLiveSession() async throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try RestorePreviewCache.prepare(home: root)
        let stale = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: stale, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try Data("private preview".utf8).write(to: stale.appendingPathComponent("preview"))
        let service = try makeService(root, time: SchedulerTestClock(date: .now))
        try await service.start()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let live = cache.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: live, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try await service.start()
        #expect(FileManager.default.fileExists(atPath: live.path))
        await service.shutdown()
    }

    private func makeService(
        _ root: URL, time: SchedulerTestClock, monitor: any SystemEventMonitoring = RuntimeMonitor()
    ) throws -> LocalBackupService {
        try LocalBackupService(
            executable: root.appendingPathComponent("absent"), home: root, temporary: root,
            expectedVersion: "0.23.1", secrets: ServiceTestSecrets(), sourceAccess: UnknownPreflightObservations(),
            protection: ManualTestProtection(), clock: time, monitor: monitor, runtimeClock: ServiceClock(time),
            now: { time.date }, loginDate: time.date)
    }
}

private actor RestartableServiceMonitor: SystemEventMonitoring {
    private(set) var count = 0
    private var current: RuntimeMonitor?
    func observe(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws {
        let monitor = RuntimeMonitor()
        current = monitor
        count += 1
        try await monitor.observe(deliver: deliver)
    }
    func fail() async { await current?.fail() }
}
