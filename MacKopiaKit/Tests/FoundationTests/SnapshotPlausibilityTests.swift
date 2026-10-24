import BackupDomain
import BackupEngine
import Foundation
import KopiaServer
import Persistence
import Testing

@testable import BackupEngine

struct SnapshotPlausibilityTests {
    @Test func exactDropThresholdsAndLargeCounters() {
        #expect(!SnapshotPlausibilityGuard.dropped(previous: 100, current: 50, percent: 50))
        #expect(SnapshotPlausibilityGuard.dropped(previous: 100, current: 49, percent: 50))
        #expect(SnapshotPlausibilityGuard.dropped(previous: 3, current: 1, percent: 50))
        #expect(!SnapshotPlausibilityGuard.dropped(previous: 0, current: 0, percent: 50))
        #expect(!SnapshotPlausibilityGuard.dropped(previous: 100, current: 101, percent: 50))
        #expect(!SnapshotPlausibilityGuard.dropped(previous: 100, current: 0, percent: 100))
        #expect(SnapshotPlausibilityGuard.dropped(previous: Int64.max, current: Int64.max / 2, percent: 50))
        #expect(!SnapshotPlausibilityGuard.dropped(previous: Int64.max, current: Int64.max / 2 + 1, percent: 50))
        #expect(SnapshotPlausibilityGuard.dropped(previous: 100, current: 74, percent: 25))
    }

    @Test func thresholdConfigAndOldHistoryRemainCompatible() throws {
        let options = try PlanOptions(lowPriority: false, ejectVolumeAfterBackup: false, plausibilityDropPercent: 25)
        #expect(try JSONDecoder().decode(PlanOptions.self, from: JSONEncoder().encode(options)) == options)
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        old.removeValue(forKey: "plausibilityDropPercent")
        #expect(
            try JSONDecoder().decode(PlanOptions.self, from: JSONSerialization.data(withJSONObject: old))
                .plausibilityDropPercent == 50)
        for invalid in [0, -1, 101] {
            #expect(throws: DomainValidationError.invalidPlan) {
                try PlanOptions(lowPriority: false, ejectVolumeAfterBackup: false, plausibilityDropPercent: invalid)
            }
        }
        let original = JobRun.SourceResult(
            sourceID: UUID(), snapshotID: "old", rootID: "root", bytes: 1, files: 1, errors: 0)
        #expect(try JSONDecoder().decode(JobRun.SourceResult.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func baselineUsesLatestCompleteTimestampAndRejectsMalformedEvidence() throws {
        func snapshot(_ id: String, date: String, incomplete: String = "") throws -> KopiaSnapshot {
            try JSONDecoder().decode(
                KopiaSnapshot.self,
                from: JSONSerialization.data(withJSONObject: [
                    "id": id, "startTime": date, "endTime": date, "incomplete": incomplete,
                    "summary": ["files": 10, "size": 20],
                ]))
        }
        let old = try snapshot("old", date: "2026-10-24T01:00:00Z")
        let latest = try snapshot("latest", date: "2026-10-25T01:00:00.123Z")
        let interrupted = try snapshot("partial", date: "bad", incomplete: "cancelled")
        #expect(try SnapshotPlausibilityGuard.baseline([latest, interrupted, old])?.id == "latest")
        #expect(try SnapshotPlausibilityGuard.baseline([interrupted]) == nil)
        #expect(throws: BackupOperationError.sourceResponseInvalid) {
            try SnapshotPlausibilityGuard.baseline([snapshot("bad", date: "invalid")])
        }
    }

    @Test(arguments: [PlausibilityTestService.Mode.success, .rejected, .lostResponse, .wrongRoot])
    func suspiciousSourcesPinOnceAndRecordConfirmedOrFailedProtection(mode: PlausibilityTestService.Mode) async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let service = PlausibilityTestService(mode: mode)
        let history = RuntimeHistory()
        let engine = try engine(fixture, service: service, history: history)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let run = try #require(try await engine.performNext())
        let pinFailed = mode == .rejected || mode == .wrongRoot
        #expect(run.outcome == .succeededWithWarnings)
        #expect(run.issues == (pinFailed ? [.suspiciousSnapshot, .snapshotPinFailed] : [.suspiciousSnapshot]))
        #expect(await service.pinRequests == 2)
        #expect(run.sources.allSatisfy { $0.issues?.contains(.suspiciousSnapshot) == true })
        #expect(run.sources.allSatisfy { $0.snapshotID.hasPrefix("pinned-") == !pinFailed })
        #expect(await service.base.closed)
        #expect(await history.finished == [run])
        let health = HealthEvaluator.evaluate(
            plan: fixture.plan, history: JobHealthHistory(latestSuccess: run, latestFinished: run),
            observations: HealthObservations(), now: run.endedAt)
        #expect(health.severity == .critical)
        #expect(health.reasons.contains(.snapshotPinFailed) == pinFailed)
    }

    @Test func cancellationDuringPinRetainsProtectedSnapshotAndStopsRemainingSources() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let service = PlausibilityTestService(mode: .held)
        let history = RuntimeHistory()
        let alerts = RuntimeIssues()
        let engine = try engine(fixture, service: service, history: history)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let running = Task {
            try await engine.performNext(suspiciousSnapshot: { run in
                #expect(await service.base.closed)
                #expect(await history.finished == [run])
                await alerts.record(.suspiciousSnapshot(planID: run.planID, runID: run.id))
            })
        }
        try await waitForRuntime { await service.pinRequests == 1 }
        running.cancel()
        #expect(await service.base.closed == false)
        await service.releasePin()
        await #expect(throws: CancellationError.self) { try await running.value }
        let run = try #require(await history.finished.first)
        #expect(run.outcome == .cancelled)
        #expect(run.issues.contains(.suspiciousSnapshot))
        #expect(run.sources.count == 1)
        #expect(run.sources.first?.snapshotID.hasPrefix("pinned-") == true)
        #expect(await service.base.closed)
        #expect(await alerts.values == [.suspiciousSnapshot(planID: fixture.plan.id, runID: run.id)])
    }

    @Test func automaticWarningSurvivesHistoryReopenAndProducesCriticalHealthAndEvent() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let service = PlausibilityTestService()
        let runtime = AutomaticBackupRuntime(
            store: fixture.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.preflight, protection: ManualTestProtection()),
            sessions: PlausibilityTestSessions(service: service), history: history,
            resolver: try TimeMachineExclusionResolver(), homeDirectory: "/Home", loginDate: fixture.time.date,
            clock: fixture.time, now: { fixture.time.date }, monitor: fixture.monitor, jitter: { 0 },
            issue: { await fixture.issues.record($0) })
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.issues.values.count == 1 }
        await runtime.shutdown()
        let reopened = try HistoryStore(directory: root)
        let run = try #require(try await reopened.recent().first)
        #expect(await fixture.issues.values == [.suspiciousSnapshot(planID: fixture.plan.id, runID: run.id)])
        let reader = try fixture.runtime(historyOverride: reopened)
        let report = try await reader.health(planID: fixture.plan.id)
        #expect(report.severity == .critical)
        #expect(report.reasons.contains(.suspiciousSnapshot))
        #expect(HealthAssessment.Reason.suspiciousSnapshot.action == .reviewActivity)
    }

    private func engine(
        _ fixture: AutomaticRuntimeFixture, service: PlausibilityTestService, history: RuntimeHistory
    )
        throws -> ManualBackupEngine
    {
        ManualBackupEngine(
            runner: ConfiguredJobRunner(
                store: fixture.store, queue: JobQueue(),
                coordinator: BackupOperationCoordinator(
                    preflight: fixture.base.preflight, protection: ManualTestProtection())),
            sessions: PlausibilityTestSessions(service: service), history: history,
            resolver: try TimeMachineExclusionResolver(), homeDirectory: "/Home")
    }
}
