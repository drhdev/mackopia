import Foundation

/// Completed trust checks contain only identities and fixed outcomes, never paths or raw diagnostics.
public struct VerificationResult: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case snapshotVerify, testRestore }
    public enum Outcome: String, Codable, Sendable { case succeeded, failed }

    public let id: UUID
    public let planID: UUID
    public let repositoryID: UUID
    public let kind: Kind
    public let startedAt: Date
    public let endedAt: Date
    public let dueAt: Date
    /// Nil preserves legacy evidence without claiming a known sampling percentage.
    public let filesPercent: Int?
    public let outcome: Outcome

    public init(
        id: UUID = UUID(), planID: UUID, repositoryID: UUID, kind: Kind,
        startedAt: Date, endedAt: Date, dueAt: Date, outcome: Outcome, filesPercent: Int? = nil
    ) {
        self.id = id
        self.planID = planID
        self.repositoryID = repositoryID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.dueAt = dueAt
        self.outcome = outcome
        self.filesPercent = filesPercent
    }
}
