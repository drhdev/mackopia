import Foundation

/// The service supplies facts; delivery stores only the decision's UUID/date ledger.
public enum BackupNotificationKind: Sendable, Equatable { case problem, firstSuccess }

public enum BackupNotificationPolicy {
    public static func decision(
        plan: PlanRuntimeState, now: Date, lastProblem: Date?, firstSuccessSent: Bool
    ) -> BackupNotificationKind? {
        let problem =
            (plan.issue != nil && plan.issue != .waitingConditions) || plan.health.severity == .critical
            || plan.health.reasons.contains(.lastRunFailed) || plan.health.reasons.contains(.lastRunWarnings)
            || plan.health.reasons.contains(.suspiciousSnapshot)
        if problem {
            if let lastProblem, now.timeIntervalSince(lastProblem) < 24 * 60 * 60 { return nil }
            return .problem
        }
        return !firstSuccessSent && plan.health.lastSuccessfulBackup != nil ? .firstSuccess : nil
    }
}
