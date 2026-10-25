import Foundation

/// A bounded UI projection. Credentials and raw subprocess errors never enter this state.
public struct LocalServiceState: Codable, Sendable {
    public let configuration: BackupConfiguration?
    public let runs: [JobRun]
    public let activePlanID: UUID?
    public let progress: BackupProgress?
    public let issue: LocalServiceIssue?
    public let revision: UUID

    public init(
        configuration: BackupConfiguration?, runs: [JobRun] = [], activePlanID: UUID? = nil,
        progress: BackupProgress? = nil, issue: LocalServiceIssue? = nil, revision: UUID = UUID()
    ) {
        self.configuration = configuration
        self.runs = Array(runs.prefix(50))
        self.activePlanID = activePlanID
        self.progress = progress
        self.issue = issue
        self.revision = revision
    }
}

public enum LocalServiceIssue: String, Error, Codable, Sendable, LocalizedError, CustomDebugStringConvertible {
    case invalidRequest, busy, unavailable, safeMode, keychain, permissions, destination, backupFailed
    public var errorDescription: String? { String(localized: "Dienstanfrage fehlgeschlagen.") }
    public var debugDescription: String { "Local service: " + rawValue }
}
