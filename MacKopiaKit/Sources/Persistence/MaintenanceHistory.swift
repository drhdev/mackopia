import BackupDomain
import Foundation
import GRDB

extension HistoryStore {
    package func recordMaintenance(_ result: MaintenanceResult) throws {
        guard result.endedAt.timeIntervalSinceReferenceDate.isFinite,
            result.endedAt >= .distantPast, result.endedAt <= .distantFuture
        else {
            throw ConfigStoreError.invalidConfiguration
        }
        do {
            let data = try JSONEncoder().encode(result)
            try database.write { db in
                try db.execute(
                    sql: "INSERT INTO maintenance (id, repositoryID, endedAt, payload) VALUES (?, ?, ?, ?)",
                    arguments: [
                        result.id.uuidString, result.repositoryID.uuidString,
                        result.endedAt.timeIntervalSinceReferenceDate, data,
                    ])
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    package func latestMaintenance(repositoryID: UUID, before: Date = .now) throws -> MaintenanceResult? {
        guard before.timeIntervalSinceReferenceDate.isFinite, before >= .distantPast, before <= .distantFuture else {
            throw ConfigStoreError.invalidConfiguration
        }
        do {
            return try database.read { db in
                guard
                    let data = try Data.fetchOne(
                        db,
                        sql:
                            "SELECT payload FROM maintenance WHERE repositoryID = ? AND endedAt <= ? ORDER BY endedAt DESC, (json_extract(CAST(payload AS TEXT), '$.outcome') = 'failed') DESC, id DESC LIMIT 1",
                        arguments: [repositoryID.uuidString, before.timeIntervalSinceReferenceDate])
                else { return nil }
                let result = try JSONDecoder().decode(MaintenanceResult.self, from: data)
                guard result.repositoryID == repositoryID, result.endedAt.timeIntervalSinceReferenceDate.isFinite,
                    result.endedAt <= before
                else {
                    throw ConfigStoreError.storageUnavailable
                }
                return result
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }
}
