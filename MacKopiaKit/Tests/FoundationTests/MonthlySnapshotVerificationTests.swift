import BackupDomain
import Foundation
import Persistence
import Testing

@testable import BackupEngine
@testable import Persistence

struct MonthlySnapshotVerificationTests {
    private let day: TimeInterval = 24 * 60 * 60

    @Test func weeklyChecksAndRestartCannotPostponeMonthlyBoundary() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let probe = VerificationProbe()
        let engine = fixture.engine(probe)
        let schedule = AutomaticSnapshotVerification(
            engine: engine, history: fixture.history, now: { fixture.base.time.date })
        try await schedule.afterBackup(run)
        let first = try #require(try await fixture.latest())
        #expect(first.filesPercent == 10)
        for _ in 0..<4 {
            fixture.base.time.advance(7 * day)
            try await schedule.afterBackup(run)
            #expect(await probe.percent == 1)
        }
        #expect(await probe.calls == 5)
        fixture.base.time.advance(2 * day - 1)
        let reopened = try HistoryStore(directory: fixture.root)
        let restarted = AutomaticSnapshotVerification(
            engine: engine, history: reopened, now: { fixture.base.time.date })
        try await restarted.afterBackup(run)
        #expect(await probe.calls == 5)
        fixture.base.time.advance(1)
        try await restarted.afterBackup(run)
        #expect(await probe.calls == 6)
        #expect(await probe.percent == 10)
        #expect(try await fixture.latest()?.endedAt == first.endedAt.addingTimeInterval(30 * day))
        #expect(try await fixture.latest()?.filesPercent == 10)
        // The larger sample remains due for a weekly refresh after seven days.
        #expect(try await fixture.latest()?.dueAt == fixture.base.time.date.addingTimeInterval(7 * day))
    }

    @Test func failedMonthlyAttemptHasIndependentIntervalFromNewWeeklySuccess() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let failure = VerificationProbe(mode: .failure)
        let failedSchedule = AutomaticSnapshotVerification(
            engine: fixture.engine(failure), history: fixture.history, now: { fixture.base.time.date })
        await #expect(throws: (any Error).self) { try await failedSchedule.afterBackup(run) }
        #expect(try await fixture.latest()?.filesPercent == 10)
        #expect(try await fixture.latest()?.outcome == .failed)
        let success = VerificationProbe()
        let schedule = AutomaticSnapshotVerification(
            engine: fixture.engine(success), history: fixture.history, now: { fixture.base.time.date })
        try await schedule.afterBackup(run)
        #expect(await success.calls == 0)
        fixture.base.time.advance(7 * day)
        try await schedule.afterBackup(run)
        #expect(await success.percent == 1)
        #expect(try await fixture.latest()?.outcome == .succeeded)
        fixture.base.time.advance(23 * day)
        try await schedule.afterBackup(run)
        #expect(await success.calls == 2)
        #expect(await success.percent == 10)
    }

    @Test func explicitLargerSampleCountsWithoutSkippingWeeklyRefresh() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let probe = VerificationProbe()
        let engine = fixture.engine(probe)
        _ = try await engine.verify(planID: run.planID, filesPercent: 100, validFor: .seconds(31 * day))
        let schedule = AutomaticSnapshotVerification(
            engine: engine, history: fixture.history, now: { fixture.base.time.date })
        try await schedule.afterBackup(run)
        #expect(await probe.calls == 1)
        fixture.base.time.advance(7 * day)
        try await schedule.afterBackup(run)
        #expect(await probe.calls == 2)
        #expect(await probe.percent == 1)
    }

    @Test func unknownSmallForeignAndFutureSamplesCannotSatisfyMonthlyStage() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let run = try await fixture.seedBackup()
        let date = fixture.base.time.date
        for (percent, planID, repositoryID, end) in [
            (nil, run.planID, run.repositoryID, date),
            (1, run.planID, run.repositoryID, date),
            (9, run.planID, run.repositoryID, date),
            (100, UUID(), run.repositoryID, date),
            (100, run.planID, UUID(), date),
            (100, run.planID, run.repositoryID, date.addingTimeInterval(1)),
        ] as [(Int?, UUID, UUID, Date)] {
            try await fixture.history.recordVerification(
                VerificationResult(
                    planID: planID, repositoryID: repositoryID, kind: .snapshotVerify,
                    startedAt: end, endedAt: end, dueAt: end.addingTimeInterval(31 * day),
                    outcome: .succeeded, filesPercent: percent))
        }
        let probe = VerificationProbe()
        try await AutomaticSnapshotVerification(
            engine: fixture.engine(probe), history: fixture.history, now: { fixture.base.time.date }
        ).afterBackup(run)
        #expect(await probe.calls == 1)
        #expect(await probe.percent == 10)
    }

    @Test func monthlyLookupPreservesFailureTieAndRejectsCorruptEvidence() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let date = fixture.base.time.date
        let plan = fixture.base.plan
        let failure = VerificationResult(
            planID: plan.id, repositoryID: plan.repositoryID, kind: .snapshotVerify,
            startedAt: date, endedAt: date, dueAt: date.addingTimeInterval(day),
            outcome: .failed, filesPercent: 10)
        let success = VerificationResult(
            planID: plan.id, repositoryID: plan.repositoryID, kind: .snapshotVerify,
            startedAt: date, endedAt: date, dueAt: date.addingTimeInterval(day),
            outcome: .succeeded, filesPercent: 100)
        for result in [failure, success] { try await fixture.history.recordVerification(result) }
        let reopened = try HistoryStore(directory: fixture.root)
        #expect(
            try await reopened.latestVerification(
                planID: plan.id, repositoryID: plan.repositoryID, kind: .snapshotVerify,
                before: date, minimumFilesPercent: 10) == failure)
        let database = await reopened.database
        try await database.write { db in
            try db.execute(
                sql: "UPDATE verifications SET payload = ? WHERE id = ?",
                arguments: [Data("invalid-json".utf8), failure.id.uuidString])
        }
        await #expect(throws: ConfigStoreError.storageUnavailable) {
            try await reopened.latestVerification(
                planID: plan.id, repositoryID: plan.repositoryID, kind: .snapshotVerify,
                before: date, minimumFilesPercent: 10)
        }
    }

    @Test func legacyPayloadAndInvalidSamplingMetadata() async throws {
        let fixture = try await VerificationEngineFixture()
        defer { fixture.remove() }
        let date = fixture.base.time.date
        let legacy = VerificationResult(
            planID: fixture.base.plan.id, repositoryID: fixture.base.plan.repositoryID, kind: .snapshotVerify,
            startedAt: date, endedAt: date, dueAt: date.addingTimeInterval(day), outcome: .succeeded)
        let payload = try JSONEncoder().encode(legacy)
        #expect(!String(decoding: payload, as: UTF8.self).contains("filesPercent"))
        #expect(try JSONDecoder().decode(VerificationResult.self, from: payload) == legacy)
        try await fixture.history.recordVerification(legacy)
        for (kind, percent) in [
            (VerificationResult.Kind.snapshotVerify, 0), (.snapshotVerify, 101), (.testRestore, 10),
        ] {
            let invalid = VerificationResult(
                planID: legacy.planID, repositoryID: legacy.repositoryID, kind: kind,
                startedAt: date, endedAt: date, dueAt: legacy.dueAt, outcome: .succeeded, filesPercent: percent)
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await fixture.history.recordVerification(invalid)
            }
        }
        for percent in [0, 101] {
            await #expect(throws: ConfigStoreError.invalidConfiguration) {
                try await fixture.history.latestVerification(
                    planID: legacy.planID, repositoryID: legacy.repositoryID, kind: .snapshotVerify,
                    before: date, minimumFilesPercent: percent)
            }
        }
        #expect(try await fixture.latest() == legacy)
        #expect(
            try await fixture.history.latestVerification(
                planID: legacy.planID, repositoryID: legacy.repositoryID, kind: .snapshotVerify,
                before: date, minimumFilesPercent: 10) == nil)
    }
}
