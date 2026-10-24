import BackupDomain
import Foundation

/// Restart intent only. Paths, credentials and old mount/network evidence are never persisted.
package struct StoredBackupWork: Codable, Sendable, Equatable {
    package enum State: String, Codable, Sendable { case pending, active, interrupted }
    package let id: UUID
    package let planID: UUID
    package let repositoryID: UUID
    package let trigger: Trigger
    package let requestedAt: Date
    package let state: State

    package init(id: UUID, planID: UUID, repositoryID: UUID, trigger: Trigger, requestedAt: Date, state: State) {
        self.id = id
        self.planID = planID
        self.repositoryID = repositoryID
        self.trigger = trigger
        self.requestedAt = requestedAt
        self.state = state
    }

    package static func validate(_ work: [Self]) throws {
        guard work.count <= 8192, Set(work.map(\.id)).count == work.count else {
            throw ConfigStoreError.invalidConfiguration
        }
        var pending: Set<UUID> = []
        var active: Set<UUID> = []
        for item in work {
            guard item.requestedAt.timeIntervalSinceReferenceDate.isFinite,
                item.requestedAt >= .distantPast, item.requestedAt <= .distantFuture,
                (item.state == .pending ? pending.insert(item.planID).inserted : active.insert(item.planID).inserted)
            else { throw ConfigStoreError.invalidConfiguration }
            do { try item.trigger.validate() } catch { throw ConfigStoreError.invalidConfiguration }
        }
    }
}

package protocol BackupWorkStoring: BackupPauseStoring {
    func loadWork() throws -> [StoredBackupWork]
    func saveWork(_ work: [StoredBackupWork]) throws
}
