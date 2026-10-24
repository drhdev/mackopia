import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import Persistence

struct HealthTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func thresholdsAndVerificationNeverInventHealthyEvidence() throws {
        let plan = try PreflightTestFixture().plan
        var observations = HealthObservations()
        observations.verification = .successful(
            checkedAt: now.addingTimeInterval(-60), dueAt: now.addingTimeInterval(60))
        for (age, severity, reason) in [
            (0.0, HealthAssessment.Severity.ok, Optional<HealthAssessment.Reason>.none),
            (259_200, .warning, .backupOverdue), (604_800, .critical, .backupCriticallyOverdue),
        ] {
            let success = run(plan, date: now.addingTimeInterval(-age), outcome: .succeeded)
            let report = HealthEvaluator.evaluate(
                plan: plan, history: JobHealthHistory(latestSuccess: success, latestFinished: success),
                observations: observations, now: now)
            #expect(report.severity == severity)
            #expect(report.reasons == reason.map { [$0] } ?? [])
        }
        let empty = JobHealthHistory(latestSuccess: nil, latestFinished: nil)
        let missing = HealthEvaluator.evaluate(plan: plan, history: empty, observations: HealthObservations(), now: now)
        #expect(missing.reasons == [.noSuccessfulBackup, .verificationUnavailable])
        #expect(missing.lastSuccessfulBackup == nil)
        #expect(
            HealthEvaluator.evaluate(plan: plan, history: nil, observations: observations, now: now).severity
                == .critical)
    }

    @Test func failuresKeepLastSuccessAndWarningsWithConcreteActions() throws {
        let plan = try PreflightTestFixture().plan
        let success = run(plan, date: now.addingTimeInterval(-60), outcome: .succeededWithWarnings)
        let latest = run(plan, date: now, outcome: .failed)
        var observations = HealthObservations()
        observations.blockers = [
            .passwordMissing, .passwordIncorrect, .fullDiskAccessMissing, .backgroundServiceDisabled,
        ]
        observations.verification = .failed
        observations.capacity = (used: 91, total: 100)
        let report = HealthEvaluator.evaluate(
            plan: plan, history: JobHealthHistory(latestSuccess: success, latestFinished: latest),
            observations: observations, now: now)
        #expect(report.severity == .critical)
        #expect(report.lastSuccessfulBackup == success.endedAt)
        #expect(
            Set(report.reasons) == [
                .lastRunFailed, .lastRunWarnings, .passwordMissing, .passwordIncorrect, .fullDiskAccessMissing,
                .backgroundServiceDisabled, .verificationFailed, .destinationNearlyFull,
            ])
        #expect(report.reasons.first?.severity == .critical)
        #expect(HealthAssessment.Reason.passwordIncorrect.action == .enterPassword)
        #expect(HealthAssessment.Reason.fullDiskAccessMissing.action == .openFullDiskAccess)
        #expect(HealthAssessment.Reason.backgroundServiceDisabled.action == .enableBackgroundService)
        #expect(HealthAssessment.Reason.verificationFailed.action == .runVerification)
    }

    @Test func verificationDatesAndCapacityBoundaries() throws {
        let plan = try PreflightTestFixture().plan
        let success = run(plan, date: now, outcome: .succeeded)
        let history = JobHealthHistory(latestSuccess: success, latestFinished: success)
        var observations = HealthObservations()
        for verification in [
            HealthObservations.Verification.successful(
                checkedAt: now.addingTimeInterval(1), dueAt: now.addingTimeInterval(60)),
            .successful(checkedAt: now, dueAt: now),
            .successful(checkedAt: Date(timeIntervalSince1970: .nan), dueAt: now),
        ] {
            observations.verification = verification
            #expect(
                HealthEvaluator.evaluate(plan: plan, history: history, observations: observations, now: now).reasons
                    == [.verificationUnavailable])
        }
        observations.verification = .successful(checkedAt: now.addingTimeInterval(-60), dueAt: now)
        #expect(
            HealthEvaluator.evaluate(plan: plan, history: history, observations: observations, now: now).reasons
                == [.verificationOverdue])
        observations.verification = .successful(
            checkedAt: now.addingTimeInterval(-60), dueAt: now.addingTimeInterval(60))
        for capacity in [(90 as Int64, 100 as Int64), (-1, 100), (101, 100), (0, 0)] {
            observations.capacity = (used: capacity.0, total: capacity.1)
            #expect(
                HealthEvaluator.evaluate(plan: plan, history: history, observations: observations, now: now).severity
                    == .ok)
        }
        observations.capacity = (used: Int64.max, total: Int64.max)
        #expect(
            HealthEvaluator.evaluate(plan: plan, history: history, observations: observations, now: now).reasons
                == [.destinationNearlyFull])
    }

    @Test func reopenedHistoryUsesCompleteDestinationScopedEvidenceThroughRuntime() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let success = run(fixture.plan, date: date.addingTimeInterval(-300), outcome: .succeeded)
        try await record(success, history: history)
        let failed = run(fixture.plan, date: date.addingTimeInterval(-60), outcome: .failed)
        try await record(failed, history: history)
        try await record(run(fixture.plan, date: date.addingTimeInterval(60), outcome: .succeeded), history: history)
        try await record(run(fixture.plan, date: date, outcome: .succeeded, repositoryID: UUID()), history: history)
        for _ in 0..<105 {
            try await record(run(fixture.plan, date: date, outcome: .running), history: history)
        }
        let reopened = try HistoryStore(directory: root)
        let evidence = try await reopened.healthHistory(
            planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, before: date)
        #expect(evidence.latestSuccess == success)
        #expect(evidence.latestFinished == failed)
        let runtime = try fixture.runtime(historyOverride: reopened)
        let report = try await runtime.health(planID: fixture.plan.id)
        #expect(report.lastSuccessfulBackup == success.endedAt)
        #expect(report.reasons == [.lastRunFailed, .verificationUnavailable])
        #expect(await fixture.sessions.opens == 0)
        #expect(await fixture.monitor.observing == false)
        await #expect(throws: JobAdmissionError.planUnavailable) { try await runtime.health(planID: UUID()) }
        await #expect(throws: ConfigStoreError.invalidConfiguration) {
            try await reopened.healthHistory(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                before: Date(timeIntervalSince1970: .infinity))
        }
    }

    @Test func unavailableHistoryAndCancellationRemainVisible() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let missing = try fixture.runtime()
        #expect(try await missing.health(planID: fixture.plan.id).reasons.contains(.historyUnavailable))
        let failed = try fixture.runtime(historyOverride: FailedHealthHistory())
        #expect(try await failed.health(planID: fixture.plan.id).severity == .critical)
        let cancelled = try fixture.runtime(historyOverride: FailedHealthHistory(cancelled: true))
        await #expect(throws: CancellationError.self) { try await cancelled.health(planID: fixture.plan.id) }
    }

    @Test func corruptHistoryProducesCriticalReportInsteadOfSuccessfulFallback() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let success = run(fixture.plan, date: fixture.time.date, outcome: .succeeded)
        try await record(success, history: history)
        let database = await history.database
        try await database.write { db in
            try db.execute(
                sql: "UPDATE runs SET payload = ? WHERE id = ?",
                arguments: [Data("invalid-json".utf8), success.id.uuidString])
        }
        let runtime = try fixture.runtime(historyOverride: history)
        let report = try await runtime.health(planID: fixture.plan.id)
        #expect(report.reasons.contains(.historyUnavailable))
        #expect(report.severity == .critical)
        #expect(report.lastSuccessfulBackup == nil)
    }

    @Test func configurationEditDuringHistoryReadRejectsStaleReport() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let history = HeldHealthHistory()
        let runtime = try fixture.runtime(historyOverride: history)
        let reading = Task { try await runtime.health(planID: fixture.plan.id) }
        try await waitForRuntime { await history.reading }
        try await fixture.store.save(BackupConfiguration(repositories: [fixture.base.repository], plans: []))
        await history.release()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await reading.value }
    }

    private func run(_ plan: BackupPlan, date: Date, outcome: JobRun.Outcome, repositoryID: UUID? = nil) -> JobRun {
        JobRun(
            id: UUID(), planID: plan.id, repositoryID: repositoryID ?? plan.repositoryID, trigger: .manual,
            startedAt: date.addingTimeInterval(-10), endedAt: date, outcome: outcome, sources: [], issues: [])
    }

    private func record(_ run: JobRun, history: HistoryStore) async throws {
        try await history.begin(
            JobRun(
                id: run.id, planID: run.planID, repositoryID: run.repositoryID, trigger: run.trigger,
                startedAt: run.startedAt, endedAt: run.endedAt, outcome: .running, sources: [], issues: []))
        if run.outcome != .running { try await history.finish(run) }
    }
}

private struct FailedHealthHistory: JobHistoryRecording, JobHistoryHealthReading {
    var cancelled = false
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func healthHistory(planID: UUID, repositoryID: UUID, before: Date) throws -> JobHealthHistory {
        if cancelled { throw CancellationError() }
        throw ConfigStoreError.storageUnavailable
    }
}

private actor HeldHealthHistory: JobHistoryRecording, JobHistoryHealthReading {
    var reading = false
    private var continuation: CheckedContinuation<Void, Never>?
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func healthHistory(planID: UUID, repositoryID: UUID, before: Date) async -> JobHealthHistory {
        reading = true
        await withCheckedContinuation { continuation = $0 }
        return JobHealthHistory(latestSuccess: nil, latestFinished: nil)
    }
    func release() { continuation?.resume(); continuation = nil }
}
