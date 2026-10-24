import BackupDomain
import Foundation
import Persistence

extension AutomaticBackupRuntime {
    /// Read-only assessment; history failure is visible and never turns into an empty/healthy result.
    package func health(
        planID: UUID, observations: HealthObservations = HealthObservations()
    ) async throws
        -> HealthAssessment
    {
        let configuration = try await store.currentConfiguration()
        guard let plan = configuration.plans.first(where: { $0.id == planID }) else {
            throw JobAdmissionError.planUnavailable
        }
        let date = now()
        guard date.timeIntervalSinceReferenceDate.isFinite, date >= .distantPast, date <= .distantFuture else {
            throw ConfigStoreError.invalidConfiguration
        }
        var history: JobHealthHistory?
        if let historyHealth {
            do {
                history = try await historyHealth.healthHistory(
                    planID: plan.id, repositoryID: plan.repositoryID, before: date)
            } catch is CancellationError { throw CancellationError() } catch { history = nil }
        }
        try Task.checkCancellation()
        guard try await store.currentConfiguration() == configuration else {
            throw JobAdmissionError.configurationChanged
        }
        var observations = observations
        if let verification = history?.latestVerification {
            // A caller's transient success cannot erase a durable failure. A newly recorded
            // successful verify is required; test restores are a separate kind of evidence.
            if verification.outcome == .failed {
                observations.verification = .failed
            } else {
                switch observations.verification {
                // Preserve a fresh failure even before its durable write completes.
                case .failed: break
                default:
                    observations.verification = .successful(
                        checkedAt: verification.endedAt, dueAt: verification.dueAt)
                }
            }
        }
        return HealthEvaluator.evaluate(plan: plan, history: history, observations: observations, now: date)
    }
}
