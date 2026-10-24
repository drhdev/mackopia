import BackupDomain
import Darwin
import Foundation
import GRDB

package protocol JobHistoryRecording: Sendable {
    func begin(_ run: JobRun) async throws
    func finish(_ run: JobRun) async throws
}

/// Agent-owned SQLite history. In-progress rows survive crashes; they never imply successful backups.
package actor HistoryStore: JobHistoryRecording, JobHistoryScheduleReading {
    let database: DatabaseQueue

    package init(directory: URL) throws {
        do {
            let files = try LocalConfigFileSystem(directory: directory)
            database = try files.withLock { _ in
                let path = directory.appendingPathComponent("history.sqlite").path
                // The private directory excludes other users. As with ConfigStore, a hostile process
                // with the same UID can race these checks; this is not a same-user security boundary.
                for suffix in ["", "-journal", "-wal", "-shm"] {
                    let descriptor = open(
                        path + suffix, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (suffix.isEmpty ? O_CREAT : 0),
                        0o600)
                    if descriptor < 0 {
                        if errno == ENOENT, !suffix.isEmpty { continue }
                        throw ConfigStoreError.unsafeStorage
                    }
                    defer { close(descriptor) }
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_nlink == 1,
                        info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600
                    else { throw ConfigStoreError.unsafeStorage }
                }
                let queue = try DatabaseQueue(path: path)
                var migrator = DatabaseMigrator()
                migrator.registerMigration("history-v1") { db in
                    try db.create(table: "runs") { table in
                        table.primaryKey("id", .text)
                        table.column("planID", .text).notNull().indexed()
                        table.column("startedAt", .double).notNull().indexed()
                        table.column("outcome", .text).notNull()
                        table.column("payload", .blob).notNull()
                    }
                }
                migrator.registerMigration("verification-history-v1") { db in
                    try db.create(table: "verifications") { table in
                        table.primaryKey("id", .text)
                        table.column("planID", .text).notNull()
                        table.column("repositoryID", .text).notNull()
                        table.column("kind", .text).notNull()
                        table.column("endedAt", .double).notNull()
                        table.column("payload", .blob).notNull()
                    }
                    try db.create(
                        index: "verification-health", on: "verifications",
                        columns: ["planID", "repositoryID", "kind", "endedAt"])
                }
                try migrator.migrate(queue)
                return queue
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    package func begin(_ run: JobRun) throws {
        guard run.outcome == .running else { throw ConfigStoreError.invalidConfiguration }
        let data = try JSONEncoder().encode(run)
        do {
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO runs (id, planID, startedAt, outcome, payload) VALUES (?, ?, ?, ?, ?)",
                    arguments: [
                        run.id.uuidString, run.planID.uuidString, run.startedAt.timeIntervalSince1970,
                        run.outcome.rawValue, data,
                    ])
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    package func finish(_ run: JobRun) throws {
        guard run.outcome != .running else { throw ConfigStoreError.invalidConfiguration }
        let data = try JSONEncoder().encode(run)
        do {
            try database.write { db in
                try db.execute(
                    sql: "UPDATE runs SET outcome = ?, payload = ? WHERE id = ? AND outcome = ?",
                    arguments: [run.outcome.rawValue, data, run.id.uuidString, JobRun.Outcome.running.rawValue])
                guard db.changesCount == 1 else { throw ConfigStoreError.storageChanged }
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    /// Read the complete history rather than a recent-page window. Plan identity is indexed;
    /// repository identity prevents an old destination's success from delaying a changed plan.
    package func scheduleAnchors(plans: [BackupPlan], before: Date) throws -> [UUID: Date] {
        guard plans.count <= 4096, Set(plans.map(\.id)).count == plans.count,
            before.timeIntervalSinceReferenceDate.isFinite, before >= .distantPast, before <= .distantFuture
        else { throw ConfigStoreError.invalidConfiguration }
        do {
            return try database.read { db in
                var anchors: [UUID: Date] = [:]
                for plan in plans where plan.isEnabled {
                    let timestamp = try Double.fetchOne(
                        db,
                        sql: """
                            SELECT MAX(startedAt) FROM runs
                            WHERE planID = ? AND outcome IN (?, ?) AND startedAt <= ? AND startedAt >= ?
                            AND json_extract(CAST(payload AS TEXT), '$.repositoryID') = ?
                            """,
                        arguments: [
                            plan.id.uuidString, JobRun.Outcome.succeeded.rawValue,
                            JobRun.Outcome.succeededWithWarnings.rawValue, before.timeIntervalSince1970,
                            Date.distantPast.timeIntervalSince1970, plan.repositoryID.uuidString,
                        ])
                    if let timestamp {
                        guard timestamp.isFinite else { throw ConfigStoreError.storageUnavailable }
                        anchors[plan.id] = Date(timeIntervalSince1970: timestamp)
                    }
                }
                return anchors
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    package func recent(limit: Int = 100) throws -> [JobRun] {
        guard (1...1000).contains(limit) else { throw ConfigStoreError.invalidConfiguration }
        do {
            return try database.read { db in
                try Data.fetchAll(
                    db, sql: "SELECT payload FROM runs ORDER BY startedAt DESC, id LIMIT ?", arguments: [limit]
                )
                .map { try JSONDecoder().decode(JobRun.self, from: $0) }
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }
}
