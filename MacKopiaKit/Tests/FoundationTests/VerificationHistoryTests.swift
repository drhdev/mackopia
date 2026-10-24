import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import Persistence

struct VerificationHistoryTests {
    @Test func reopenedEvidenceFeedsHealthAndOnlyNewVerifyClearsFailure() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let failed = result(fixture.plan, at: date.addingTimeInterval(-60), outcome: .failed)
        try await history.recordVerification(failed)
        // An unrelated check, destination, future result or test restore must not hide the failure.
        for check in [
            result(fixture.plan, at: date, outcome: .succeeded, repositoryID: UUID()),
            result(fixture.plan, at: date.addingTimeInterval(1), outcome: .succeeded),
            result(fixture.plan, at: date, outcome: .succeeded, kind: .testRestore),
        ] { try await history.recordVerification(check) }
        let reopened = try HistoryStore(directory: root)
        let restore = try await reopened.latestVerification(
            planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, kind: .testRestore, before: date)
        #expect(restore?.kind == .testRestore)
        #expect(restore?.outcome == .succeeded)
        #expect(restore?.endedAt == date)
        #expect(
            try await reopened.latestVerification(
                planID: UUID(), repositoryID: fixture.plan.repositoryID, kind: .snapshotVerify, before: date) == nil)
        await #expect(throws: ConfigStoreError.invalidConfiguration) {
            try await reopened.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, kind: .snapshotVerify,
                before: Date(timeIntervalSince1970: .nan))
        }
        let runtime = try fixture.runtime(historyOverride: reopened)
        var observations = HealthObservations()
        observations.verification = .successful(checkedAt: date, dueAt: date.addingTimeInterval(60))
        let report = try await runtime.health(planID: fixture.plan.id, observations: observations)
        #expect(report.reasons.contains(.verificationFailed))
        #expect(report.severity == .critical)
        let evidence = try await reopened.healthHistory(
            planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, before: date)
        #expect(evidence.latestVerification == failed)
        try await reopened.recordVerification(result(fixture.plan, at: date, outcome: .succeeded))
        let healthy = try await runtime.health(planID: fixture.plan.id)
        #expect(healthy.reasons == [.noSuccessfulBackup])
        observations.verification = .failed
        #expect(
            try await runtime.health(planID: fixture.plan.id, observations: observations).reasons.contains(
                .verificationFailed))
        // Equal completion timestamps cannot arbitrarily select success by random UUID order.
        try await reopened.recordVerification(result(fixture.plan, at: date, outcome: .failed))
        #expect(try await runtime.health(planID: fixture.plan.id).reasons.contains(.verificationFailed))
        #expect(await fixture.sessions.opens == 0)
        #expect(await fixture.monitor.observing == false)
    }

    @Test func duplicateAndInvalidResultsCannotChangeHistory() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let check = result(fixture.plan, at: date, outcome: .failed)
        try await history.recordVerification(check)
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await history.recordVerification(check) }
        for (start, end, due) in [
            (date.addingTimeInterval(1), date, date.addingTimeInterval(60)),
            (date, date, date),
            (Date(timeIntervalSince1970: .nan), date, date.addingTimeInterval(60)),
            (date, date, Date(timeIntervalSince1970: .infinity)),
        ] {
            let invalid = VerificationResult(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, kind: .snapshotVerify,
                startedAt: start, endedAt: end, dueAt: due, outcome: .succeeded)
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await history.recordVerification(invalid)
            }
        }
        let stored = try await history.healthHistory(
            planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, before: date)
        #expect(stored.latestVerification == check)
    }

    @Test func overdueEvidenceAndCorruptionNeverBecomeHealthy() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let check = result(fixture.plan, at: date.addingTimeInterval(-60), outcome: .succeeded, dueAt: date)
        try await history.recordVerification(check)
        let runtime = try fixture.runtime(historyOverride: history)
        #expect(try await runtime.health(planID: fixture.plan.id).reasons.contains(.verificationOverdue))
        var observations = HealthObservations()
        observations.verification = .successful(checkedAt: date, dueAt: date.addingTimeInterval(60))
        #expect(
            try await runtime.health(planID: fixture.plan.id, observations: observations).reasons.contains(
                .verificationOverdue))
        let database = await history.database
        try await database.write { db in
            try db.execute(
                sql: "UPDATE verifications SET payload = ? WHERE id = ?",
                arguments: [Data("invalid-json".utf8), check.id.uuidString])
        }
        let report = try await runtime.health(planID: fixture.plan.id)
        #expect(report.reasons.contains(.historyUnavailable))
        #expect(report.severity == .critical)
    }

    @Test func payloadIdentityMismatchIsRejected() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let check = result(fixture.plan, at: date, outcome: .succeeded)
        try await history.recordVerification(check)
        let foreign = result(fixture.plan, at: date, outcome: .succeeded, repositoryID: UUID())
        let payload = try JSONEncoder().encode(foreign)
        let database = await history.database
        try await database.write { db in
            try db.execute(
                sql: "UPDATE verifications SET payload = ? WHERE id = ?", arguments: [payload, check.id.uuidString])
        }
        await #expect(throws: ConfigStoreError.storageUnavailable) {
            try await history.healthHistory(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID, before: date)
        }
    }

    private func result(
        _ plan: BackupPlan, at date: Date, outcome: VerificationResult.Outcome,
        kind: VerificationResult.Kind = .snapshotVerify, repositoryID: UUID? = nil, dueAt: Date? = nil
    ) -> VerificationResult {
        VerificationResult(
            planID: plan.id, repositoryID: repositoryID ?? plan.repositoryID, kind: kind,
            startedAt: date.addingTimeInterval(-10), endedAt: date,
            dueAt: dueAt ?? date.addingTimeInterval(3600), outcome: outcome)
    }
}
