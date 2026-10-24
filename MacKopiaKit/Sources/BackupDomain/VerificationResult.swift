import Foundation

/// Completed trust checks contain only identities and fixed outcomes, never paths or raw diagnostics.
package struct VerificationResult: Codable, Sendable, Hashable {
    package enum Kind: String, Codable, Sendable { case snapshotVerify, testRestore }
    package enum Outcome: String, Codable, Sendable { case succeeded, failed }

    package let id: UUID
    package let planID: UUID
    package let repositoryID: UUID
    package let kind: Kind
    package let startedAt: Date
    package let endedAt: Date
    package let dueAt: Date
    package let outcome: Outcome

    package init(
        id: UUID = UUID(), planID: UUID, repositoryID: UUID, kind: Kind,
        startedAt: Date, endedAt: Date, dueAt: Date, outcome: Outcome
    ) {
        self.id = id
        self.planID = planID
        self.repositoryID = repositoryID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.dueAt = dueAt
        self.outcome = outcome
    }
}
