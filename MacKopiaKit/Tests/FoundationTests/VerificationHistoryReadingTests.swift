import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import Persistence

struct VerificationHistoryReadingTests {
    @Test func checkKindsStaySeparateAndEqualTimeFailureWins() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        let date = fixture.time.date
        let failure = check(fixture.plan, at: date, kind: .snapshotVerify, outcome: .failed)
        let success = check(fixture.plan, at: date, kind: .snapshotVerify, outcome: .succeeded)
        let restore = check(fixture.plan, at: date, kind: .testRestore, outcome: .succeeded)
        for result in [failure, success, restore] { try await history.recordVerification(result) }
        let reopened = try HistoryStore(directory: root)
        #expect(
            try await reopened.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                kind: .snapshotVerify, before: date) == failure)
        #expect(
            try await reopened.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                kind: .testRestore, before: date) == restore)
        #expect(
            try await reopened.latestVerification(
                planID: UUID(), repositoryID: fixture.plan.repositoryID,
                kind: .testRestore, before: date) == nil)
        let runtime = try fixture.runtime(historyOverride: reopened)
        #expect(try await runtime.health(planID: fixture.plan.id).reasons.contains(.verificationFailed))
        let newer = check(
            fixture.plan, at: date.addingTimeInterval(1), kind: .snapshotVerify, outcome: .succeeded)
        try await reopened.recordVerification(newer)
        #expect(
            try await reopened.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                kind: .snapshotVerify, before: newer.endedAt) == newer)
    }

    @Test func migrationPreservesExistingRunsAndFreshFailureRemainsCritical() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try HistoryStore(directory: root)
        let date = fixture.time.date
        let running = JobRun(
            id: UUID(), planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
            trigger: .manual, startedAt: date, endedAt: date, outcome: .running, sources: [], issues: [])
        try await original.begin(running)
        let database = await original.database
        // Recreate the deployed v1 layout, including its migration marker and existing backup row.
        try await database.write { db in
            try db.execute(sql: "DROP TABLE verifications")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'verification-history-v1'")
        }
        let migrated = try HistoryStore(directory: root)
        #expect(try await migrated.recent() == [running])
        #expect(
            try await migrated.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                kind: .snapshotVerify, before: date) == nil)
        let success = check(fixture.plan, at: date, kind: .snapshotVerify, outcome: .succeeded)
        try await migrated.recordVerification(success)
        let runtime = try fixture.runtime(historyOverride: migrated)
        var observations = HealthObservations()
        observations.verification = .failed
        #expect(
            try await runtime.health(planID: fixture.plan.id, observations: observations).reasons.contains(
                .verificationFailed))
        let reopened = try HistoryStore(directory: root)
        #expect(try await reopened.recent() == [running])
        #expect(
            try await reopened.latestVerification(
                planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                kind: .snapshotVerify, before: date) == success)
        for before in [Date(timeIntervalSinceReferenceDate: .nan), Date(timeIntervalSinceReferenceDate: .infinity)] {
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await reopened.latestVerification(
                    planID: fixture.plan.id, repositoryID: fixture.plan.repositoryID,
                    kind: .snapshotVerify, before: before)
            }
        }
    }

    private func check(
        _ plan: BackupPlan, at date: Date, kind: VerificationResult.Kind, outcome: VerificationResult.Outcome
    ) -> VerificationResult {
        VerificationResult(
            planID: plan.id, repositoryID: plan.repositoryID, kind: kind,
            startedAt: date.addingTimeInterval(-10), endedAt: date,
            dueAt: date.addingTimeInterval(3600), outcome: outcome)
    }
}
