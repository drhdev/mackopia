import BackupDomain
import Foundation
import GRDB

/// Called before activating a sole runtime owner, never against a still-running engine session.
package protocol JobHistoryRecovering: Sendable {
    func reconcileInterrupted(at date: Date, workIDs: Set<UUID>) async throws -> Set<UUID>
}

extension HistoryStore: JobHistoryRecovering {
    /// One transaction closes abandoned running rows and identifies already completed intents.
    /// Cancellation does not erase durable pause/shutdown intent; stop removes that intent first.
    package func reconcileInterrupted(at date: Date, workIDs: Set<UUID>) throws -> Set<UUID> {
        guard date.timeIntervalSinceReferenceDate.isFinite, workIDs.count <= 8192 else {
            throw ConfigStoreError.invalidConfiguration
        }
        do {
            return try database.write { db in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, payload FROM runs WHERE outcome = ? ORDER BY id LIMIT 8193",
                    arguments: [JobRun.Outcome.running.rawValue])
                guard rows.count <= 8192 else { throw ConfigStoreError.invalidConfiguration }
                for row in rows {
                    let payload: Data = row["payload"]
                    let run = try JSONDecoder().decode(JobRun.self, from: payload)
                    let id: String = row["id"]
                    guard run.id.uuidString == id, run.outcome == .running,
                        run.startedAt.timeIntervalSinceReferenceDate.isFinite
                    else {
                        throw ConfigStoreError.invalidConfiguration
                    }
                    let recovered = JobRun(
                        id: run.id, planID: run.planID, repositoryID: run.repositoryID, trigger: run.trigger,
                        startedAt: run.startedAt, endedAt: max(date, run.startedAt), outcome: .cancelled,
                        sources: run.sources,
                        issues: Array(Set(run.issues + [.processInterrupted])).sorted {
                            $0.rawValue < $1.rawValue
                        })
                    try db.execute(
                        sql: "UPDATE runs SET outcome = ?, payload = ? WHERE id = ? AND outcome = ?",
                        arguments: [
                            recovered.outcome.rawValue, try JSONEncoder().encode(recovered), run.id.uuidString,
                            JobRun.Outcome.running.rawValue,
                        ])
                    guard db.changesCount == 1 else { throw ConfigStoreError.storageChanged }
                }
                var completed: Set<UUID> = []
                for id in workIDs {
                    if let value = try String.fetchOne(
                        db, sql: "SELECT outcome FROM runs WHERE id = ?", arguments: [id.uuidString])
                    {
                        guard let outcome = JobRun.Outcome(rawValue: value) else {
                            throw ConfigStoreError.invalidConfiguration
                        }
                        if outcome != .running, outcome != .cancelled { completed.insert(id) }
                    }
                }
                return completed
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }
}
