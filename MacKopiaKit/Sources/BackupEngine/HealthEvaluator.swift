import BackupDomain
import Foundation
import Persistence

/// Fresh observations supplied by the owner; missing verification evidence cannot imply success.
package struct HealthObservations: Sendable {
    package enum Verification: Sendable {
        case unavailable, failed, successful(checkedAt: Date, dueAt: Date)
    }
    package enum Blocker: Sendable {
        case passwordMissing, passwordIncorrect, fullDiskAccessMissing, backgroundServiceDisabled
    }
    package var verification: Verification = .unavailable
    package var blockers: Set<Blocker> = []
    package var destinationNearlyFull = false
    package var testRestoreFailed = false
    package var maintenanceFailed = false
    package var capacity: (used: Int64, total: Int64)?

    package init() {}
}

package enum HealthEvaluator {
    package static func evaluate(
        plan: BackupPlan, history: JobHealthHistory?, observations: HealthObservations, now: Date
    ) -> HealthAssessment {
        var reasons: Set<HealthAssessment.Reason> = []
        let success = history?.latestSuccess
        if history == nil {
            reasons.insert(.historyUnavailable)
        } else if let success {
            let age = Duration.seconds(max(0, now.timeIntervalSince(success.endedAt)))
            if age >= plan.health.criticalAfter {
                reasons.insert(.backupCriticallyOverdue)
            } else if age >= plan.health.warnAfter {
                reasons.insert(.backupOverdue)
            }
        } else {
            reasons.insert(.noSuccessfulBackup)
        }
        if let latest = history?.latestFinished {
            if latest.outcome == .failed { reasons.insert(.lastRunFailed) }
            if latest.outcome == .succeededWithWarnings { reasons.insert(.lastRunWarnings) }
        }
        // A failed attempt must not hide warnings in the latest still-recoverable backup.
        if success?.outcome == .succeededWithWarnings { reasons.insert(.lastRunWarnings) }
        for run in [history?.latestSuccess, history?.latestFinished].compactMap({ $0 }) {
            if run.issues.contains(.suspiciousSnapshot) { reasons.insert(.suspiciousSnapshot) }
            if run.issues.contains(.snapshotPinFailed) { reasons.insert(.snapshotPinFailed) }
        }
        for blocker in observations.blockers {
            switch blocker {
            case .passwordMissing: reasons.insert(.passwordMissing)
            case .passwordIncorrect: reasons.insert(.passwordIncorrect)
            case .fullDiskAccessMissing: reasons.insert(.fullDiskAccessMissing)
            case .backgroundServiceDisabled: reasons.insert(.backgroundServiceDisabled)
            }
        }
        if observations.destinationNearlyFull { reasons.insert(.destinationNearlyFull) }
        if observations.testRestoreFailed { reasons.insert(.testRestoreFailed) }
        if observations.maintenanceFailed { reasons.insert(.maintenanceFailed) }
        if let capacity = observations.capacity, capacity.total > 0, capacity.used >= 0,
            capacity.used <= capacity.total, Double(capacity.used) / Double(capacity.total) > 0.9
        {
            reasons.insert(.destinationNearlyFull)
        }
        switch observations.verification {
        case .unavailable: reasons.insert(.verificationUnavailable)
        case .failed: reasons.insert(.verificationFailed)
        case .successful(let checkedAt, let dueAt):
            if checkedAt < .distantPast || checkedAt > now || dueAt <= checkedAt
                || !checkedAt.timeIntervalSinceReferenceDate.isFinite || !dueAt.timeIntervalSinceReferenceDate.isFinite
            {
                reasons.insert(.verificationUnavailable)
            } else if dueAt <= now {
                reasons.insert(.verificationOverdue)
            }
        }
        return HealthAssessment(
            planID: plan.id, lastSuccessfulBackup: success?.endedAt,
            reasons: HealthAssessment.Reason.allCases.filter { reasons.contains($0) }
                .sorted { $0.severity > $1.severity })
    }
}
