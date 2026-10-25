import Foundation

public struct MaintenanceResult: Codable, Sendable, Identifiable, Equatable {
    public enum Outcome: String, Codable, Sendable { case succeeded, failed }
    public let id: UUID
    public let repositoryID: UUID
    public let endedAt: Date
    public let outcome: Outcome
    public init(id: UUID = UUID(), repositoryID: UUID, endedAt: Date, outcome: Outcome) {
        self.id = id; self.repositoryID = repositoryID; self.endedAt = endedAt; self.outcome = outcome
    }
}
