import Foundation

/// Sanitized run history: no child diagnostics, credentials, or source paths.
public struct JobRun: Codable, Sendable, Hashable, Identifiable {
    public enum Outcome: String, Codable, Sendable {
        case running, succeeded, succeededWithWarnings, skipped, cancelled, failed
    }
    public enum Issue: String, Codable, Sendable {
        case preflight, operation, cleanup, missingSource, fileErrors, incompleteSnapshot, cancellationUnconfirmed
    }
    public struct SourceResult: Codable, Sendable, Hashable {
        public let sourceID: UUID
        public let snapshotID: String
        public let rootID: String
        public let bytes: Int64
        public let files: Int64
        public let ignoredErrors: Int64
        public let errors: Int64

        public init(
            sourceID: UUID, snapshotID: String, rootID: String, bytes: Int64, files: Int64, errors: Int64,
            ignoredErrors: Int64 = 0
        ) {
            self.sourceID = sourceID
            self.snapshotID = snapshotID
            self.rootID = rootID
            self.bytes = bytes
            self.files = files
            self.errors = errors
            self.ignoredErrors = ignoredErrors
        }
    }

    public let id: UUID
    public let planID: UUID
    public let repositoryID: UUID
    public let trigger: Trigger
    public let startedAt: Date
    public let endedAt: Date
    public let outcome: Outcome
    public let sources: [SourceResult]
    public let issues: [Issue]

    public init(
        id: UUID, planID: UUID, repositoryID: UUID, trigger: Trigger, startedAt: Date, endedAt: Date,
        outcome: Outcome, sources: [SourceResult], issues: [Issue]
    ) {
        self.id = id
        self.planID = planID
        self.repositoryID = repositoryID
        self.trigger = trigger
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.sources = sources
        self.issues = issues
    }
}
