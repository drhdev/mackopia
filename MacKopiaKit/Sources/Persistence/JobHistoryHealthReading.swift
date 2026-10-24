import BackupDomain
import Foundation
import GRDB

package struct JobHealthHistory: Sendable {
    package let latestSuccess: JobRun?
    package let latestFinished: JobRun?
    package let latestVerification: VerificationResult?

    package init(
        latestSuccess: JobRun?, latestFinished: JobRun?, latestVerification: VerificationResult? = nil
    ) {
        self.latestSuccess = latestSuccess
        self.latestFinished = latestFinished
        self.latestVerification = latestVerification
    }
}

package protocol JobHistoryHealthReading: Sendable {
    func healthHistory(planID: UUID, repositoryID: UUID, before: Date) async throws -> JobHealthHistory
}

extension HistoryStore: JobHistoryHealthReading {
    /// Two bounded results over the complete history, in one consistent SQLite read transaction.
    package func healthHistory(planID: UUID, repositoryID: UUID, before: Date) throws -> JobHealthHistory {
        guard before.timeIntervalSinceReferenceDate.isFinite, before >= .distantPast, before <= .distantFuture else {
            throw ConfigStoreError.invalidConfiguration
        }
        do {
            return try database.read { db in
                func latest(outcomes: [JobRun.Outcome]) throws -> JobRun? {
                    let placeholders = Array(repeating: "?", count: outcomes.count).joined(separator: ",")
                    let payload = try Data.fetchOne(
                        db,
                        sql: """
                            SELECT payload FROM runs WHERE planID = ? AND outcome IN (\(placeholders))
                            AND json_extract(CAST(payload AS TEXT), '$.repositoryID') = ?
                            AND json_extract(CAST(payload AS TEXT), '$.endedAt') <= ?
                            ORDER BY json_extract(CAST(payload AS TEXT), '$.endedAt') DESC, id DESC LIMIT 1
                            """,
                        arguments: StatementArguments(
                            [planID.uuidString] + outcomes.map(\.rawValue) + [repositoryID.uuidString])
                            + StatementArguments([before.timeIntervalSinceReferenceDate]))
                    guard let payload else { return nil }
                    let run = try JSONDecoder().decode(JobRun.self, from: payload)
                    guard run.planID == planID, run.repositoryID == repositoryID, outcomes.contains(run.outcome),
                        run.startedAt >= .distantPast, run.startedAt <= run.endedAt, run.endedAt <= before
                    else { throw ConfigStoreError.storageUnavailable }
                    return run
                }
                return try JobHealthHistory(
                    latestSuccess: latest(outcomes: [.succeeded, .succeededWithWarnings]),
                    latestFinished: latest(outcomes: [
                        .succeeded, .succeededWithWarnings, .failed, .cancelled, .skipped,
                    ]),
                    latestVerification: Self.latestVerification(
                        in: db, planID: planID, repositoryID: repositoryID, before: before))
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }
}
