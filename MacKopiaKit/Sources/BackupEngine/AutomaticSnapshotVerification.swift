import BackupDomain
import Foundation
import Persistence

/// Checks become due from durable evidence, so restarting the runtime cannot reset the interval.
/// The engine must share the backup owner's repository coordinator and operation gate.
package struct AutomaticSnapshotVerification: Sendable {
    private let engine: SnapshotVerificationEngine
    private let history: any VerificationHistoryReading
    private let now: @Sendable () -> Date

    package init(
        engine: SnapshotVerificationEngine, history: any VerificationHistoryReading,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.engine = engine
        self.history = history
        self.now = now
    }

    package func afterBackup(_ run: JobRun) async throws {
        // A suspicious or incomplete backup must not start extra repository work.
        guard run.outcome == .succeeded else { return }
        try Task.checkCancellation()
        let date = now()
        let latest = try await history.latestVerification(
            planID: run.planID, repositoryID: run.repositoryID, kind: .snapshotVerify, before: date)
        try Task.checkCancellation()
        let monthly = try await history.latestVerification(
            planID: run.planID, repositoryID: run.repositoryID, kind: .snapshotVerify, before: date,
            minimumFilesPercent: 10)
        try Task.checkCancellation()
        // A larger sample also satisfies the weekly check. Weekly checks cannot postpone
        // the monthly interval, including across restarts or newer explicit small checks.
        if monthly == nil || monthly.map({ $0.endedAt.addingTimeInterval(30 * 24 * 60 * 60) <= date }) == true {
            _ = try await engine.verify(planID: run.planID, filesPercent: 10)
        } else if latest == nil
            || latest.map({ min($0.dueAt, $0.endedAt.addingTimeInterval(7 * 24 * 60 * 60)) <= date }) == true
        {
            _ = try await engine.verify(planID: run.planID)
        }
    }
}
