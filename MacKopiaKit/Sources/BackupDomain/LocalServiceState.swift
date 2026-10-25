import Foundation

/// A bounded UI projection. Credentials and raw subprocess errors never enter this state.
public struct LocalServiceState: Codable, Sendable {
    public let configuration: BackupConfiguration?
    public let runs: [JobRun]
    public let activePlanID: UUID?
    public let progress: BackupProgress?
    public let issue: LocalServiceIssue?
    public let revision: UUID
    public let plans: [PlanRuntimeState]
    public let globalPause: BackupPauseState?
    public let restore: RestoreState?

    public init(
        configuration: BackupConfiguration?, runs: [JobRun] = [], activePlanID: UUID? = nil,
        progress: BackupProgress? = nil, issue: LocalServiceIssue? = nil, revision: UUID = UUID(),
        plans: [PlanRuntimeState] = [], globalPause: BackupPauseState? = nil, restore: RestoreState? = nil
    ) {
        self.configuration = configuration
        self.runs = Array(runs.prefix(50))
        self.activePlanID = activePlanID
        self.progress = progress
        self.issue = issue
        self.revision = revision
        self.plans = plans; self.globalPause = globalPause; self.restore = restore
    }
}

public enum LocalServiceIssue: String, Error, Codable, Sendable, LocalizedError, CustomDebugStringConvertible {
    case invalidRequest, busy, unavailable, safeMode, keychain, permissions, destination, backupFailed,
        automationUnavailable, verificationFailed, maintenanceFailed, planPaused, waitingConditions
    public var errorDescription: String? { String(localized: "Dienstanfrage fehlgeschlagen.") }
    public var debugDescription: String { "Local service: " + rawValue }
}
