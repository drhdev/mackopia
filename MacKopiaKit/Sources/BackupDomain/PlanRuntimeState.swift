import Foundation

public enum BackupPauseState: Codable, Sendable, Equatable {
    case indefinite, until(Date), timerUnavailable(until: Date)
}

/// Fixed facts only. No credentials, subprocess diagnostics or source paths.
public struct PlanRuntimeState: Codable, Sendable, Identifiable {
    public var id: UUID { planID }
    public let planID: UUID
    public let nextRun: Date?
    public let pause: BackupPauseState?
    public let health: HealthAssessment
    public let verification: VerificationResult?
    public let testRestore: VerificationResult?
    public let maintenance: MaintenanceResult?
    public let issue: LocalServiceIssue?

    public init(
        planID: UUID, nextRun: Date?, pause: BackupPauseState?, health: HealthAssessment,
        verification: VerificationResult?, testRestore: VerificationResult?, maintenance: MaintenanceResult?,
        issue: LocalServiceIssue? = nil
    ) {
        self.planID = planID; self.nextRun = nextRun; self.pause = pause; self.health = health
        self.verification = verification; self.testRestore = testRestore; self.maintenance = maintenance;
        self.issue = issue
    }
}
