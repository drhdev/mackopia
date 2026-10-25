import BackupDomain
import Foundation
import GRDB

package protocol VerificationHistoryRecording: Sendable {
    func recordVerification(_ result: VerificationResult) async throws
}

package protocol VerificationHistoryReading: Sendable {
    func latestVerification(
        planID: UUID, repositoryID: UUID, kind: VerificationResult.Kind, before: Date, minimumFilesPercent: Int?
    ) async throws -> VerificationResult?
}

extension VerificationHistoryReading {
    package func latestVerification(
        planID: UUID, repositoryID: UUID, kind: VerificationResult.Kind, before: Date
    ) async throws -> VerificationResult? {
        try await latestVerification(
            planID: planID, repositoryID: repositoryID, kind: kind, before: before, minimumFilesPercent: nil)
    }
}

extension HistoryStore: VerificationHistoryRecording, VerificationHistoryReading {
    package func latestVerification(
        planID: UUID, repositoryID: UUID, kind: VerificationResult.Kind, before: Date, minimumFilesPercent: Int? = nil
    ) throws -> VerificationResult? {
        guard Self.validVerificationDate(before),
            minimumFilesPercent.map({ (1...100).contains($0) && kind == .snapshotVerify }) ?? true
        else { throw ConfigStoreError.invalidConfiguration }
        do {
            return try database.read { db in
                try Self.latestVerification(
                    in: db, planID: planID, repositoryID: repositoryID, kind: kind, before: before,
                    minimumFilesPercent: minimumFilesPercent)
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    /// Append-only: a duplicate ID cannot replace a failed check with a success.
    package func recordVerification(_ result: VerificationResult) throws {
        guard Self.validVerification(result) else { throw ConfigStoreError.invalidConfiguration }
        do {
            let payload = try JSONEncoder().encode(result)
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO verifications (id, planID, repositoryID, kind, endedAt, payload)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        result.id.uuidString, result.planID.uuidString, result.repositoryID.uuidString,
                        result.kind.rawValue, result.endedAt.timeIntervalSinceReferenceDate, payload,
                    ])
            }
        } catch { throw ConfigStoreError.storageUnavailable }
    }

    static func latestVerification(
        in db: Database, planID: UUID, repositoryID: UUID,
        kind: VerificationResult.Kind = .snapshotVerify, before: Date, minimumFilesPercent: Int? = nil
    ) throws -> VerificationResult? {
        guard
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT id, endedAt, payload FROM verifications
                    WHERE planID = ? AND repositoryID = ? AND kind = ? AND endedAt <= ?
                    AND (? IS NULL OR json_extract(CAST(payload AS TEXT), '$.filesPercent') >= ?)
                    ORDER BY endedAt DESC,
                        (json_extract(CAST(payload AS TEXT), '$.outcome') = 'failed') DESC, id DESC LIMIT 1
                    """,
                arguments: [
                    planID.uuidString, repositoryID.uuidString, kind.rawValue,
                    before.timeIntervalSinceReferenceDate, minimumFilesPercent, minimumFilesPercent,
                ])
        else { return nil }
        let payload: Data = row["payload"]
        let result = try JSONDecoder().decode(VerificationResult.self, from: payload)
        let id: String = row["id"]
        let endedAt: Double = row["endedAt"]
        guard validVerification(result), result.id.uuidString == id,
            result.planID == planID, result.repositoryID == repositoryID, result.kind == kind,
            result.endedAt.timeIntervalSinceReferenceDate == endedAt, result.endedAt <= before,
            minimumFilesPercent.map({ (result.filesPercent ?? 0) >= $0 }) ?? true
        else { throw ConfigStoreError.storageUnavailable }
        return result
    }

    private static func validVerification(_ result: VerificationResult) -> Bool {
        [result.startedAt, result.endedAt, result.dueAt].allSatisfy(validVerificationDate)
            && result.startedAt <= result.endedAt && result.dueAt > result.endedAt
            && (result.filesPercent.map({ (1...100).contains($0) && result.kind == .snapshotVerify }) ?? true)
    }

    private static func validVerificationDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }
}
