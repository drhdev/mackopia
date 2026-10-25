import BackupDomain
import Foundation
import Persistence

/// Checks become due from durable evidence, so restarting the runtime cannot reset the interval.
/// The engine must share the backup owner's repository coordinator and operation gate.
package struct AutomaticTestRestore: Sendable {
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
            planID: run.planID, repositoryID: run.repositoryID, kind: .testRestore, before: date)
        try Task.checkCancellation()
        guard latest == nil || latest.map({ $0.dueAt <= date }) == true else { return }
        _ = try await engine.testRestore(planID: run.planID)
    }
}
