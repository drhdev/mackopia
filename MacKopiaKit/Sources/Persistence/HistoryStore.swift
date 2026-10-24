import BackupDomain
import Darwin
import Foundation
import GRDB

package protocol JobHistoryRecording: Sendable {
    func begin(_ run: JobRun) async throws
    func finish(_ run: JobRun) async throws
}

/// Agent-owned SQLite history. In-progress rows survive crashes; they never imply successful backups.
package actor HistoryStore: JobHistoryRecording {
    private let database: DatabaseQueue

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
