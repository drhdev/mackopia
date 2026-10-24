import Foundation

/// Fixed facts and follow-up actions; presentation localizes these codes at the UI boundary.
public struct HealthAssessment: Sendable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case ok, warning, critical
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Action: Sendable {
        case backUpNow, reviewActivity, reviewDestination, enterPassword, openFullDiskAccess
        case enableBackgroundService, runVerification, reviewDiagnostics
    }

    public enum Reason: Sendable, CaseIterable {
        case backupOverdue, backupCriticallyOverdue, noSuccessfulBackup, lastRunWarnings, lastRunFailed
        case destinationNearlyFull, passwordMissing, passwordIncorrect, fullDiskAccessMissing
        case backgroundServiceDisabled, verificationOverdue, verificationFailed, verificationUnavailable
        case historyUnavailable
        case suspiciousSnapshot, snapshotPinFailed

        public var severity: Severity {
            switch self {
            case .backupCriticallyOverdue, .passwordMissing, .passwordIncorrect, .fullDiskAccessMissing,
                .backgroundServiceDisabled, .verificationFailed, .historyUnavailable, .suspiciousSnapshot,
                .snapshotPinFailed:
                .critical
            default: .warning
            }
        }

        public var action: Action {
            switch self {
            case .backupOverdue, .backupCriticallyOverdue, .noSuccessfulBackup: .backUpNow
            case .lastRunWarnings, .lastRunFailed, .suspiciousSnapshot, .snapshotPinFailed: .reviewActivity
            case .destinationNearlyFull: .reviewDestination
            case .passwordMissing, .passwordIncorrect: .enterPassword
            case .fullDiskAccessMissing: .openFullDiskAccess
            case .backgroundServiceDisabled: .enableBackgroundService
            case .verificationOverdue, .verificationFailed, .verificationUnavailable: .runVerification
            case .historyUnavailable: .reviewDiagnostics
            }
        }
    }

    public let planID: UUID
    public let lastSuccessfulBackup: Date?
    public let reasons: [Reason]
    public var severity: Severity { reasons.map(\.severity).max() ?? .ok }

    public init(planID: UUID, lastSuccessfulBackup: Date?, reasons: [Reason]) {
        self.planID = planID
        self.lastSuccessfulBackup = lastSuccessfulBackup
        self.reasons = reasons
    }
}
