import BackupDomain
import Foundation
import Testing

struct BackupNotificationPolicyTests {
    @Test func problemsAreLimitedToOncePerDayEvenWhenTheClockMovesBackwards() {
        let date = Date.now
        let plan = state(reasons: [.verificationFailed])
        #expect(
            BackupNotificationPolicy.decision(plan: plan, now: date, lastProblem: nil, firstSuccessSent: false)
                == .problem)
        #expect(
            BackupNotificationPolicy.decision(plan: plan, now: date, lastProblem: date, firstSuccessSent: false) == nil)
        #expect(
            BackupNotificationPolicy.decision(
                plan: plan, now: date.addingTimeInterval(-1), lastProblem: date, firstSuccessSent: false) == nil)
        #expect(
            BackupNotificationPolicy.decision(
                plan: plan, now: date.addingTimeInterval(86400), lastProblem: date, firstSuccessSent: false) == .problem
        )
    }

    @Test func firstSuccessIsSentOnceAndRoutineSuccessesStayQuiet() {
        let plan = state(reasons: [], success: .now)
        #expect(
            BackupNotificationPolicy.decision(plan: plan, now: .now, lastProblem: nil, firstSuccessSent: false)
                == .firstSuccess)
        #expect(
            BackupNotificationPolicy.decision(plan: plan, now: .now, lastProblem: nil, firstSuccessSent: true) == nil)
        #expect(
            BackupNotificationPolicy.decision(
                plan: state(reasons: [.noSuccessfulBackup]), now: .now,
                lastProblem: nil, firstSuccessSent: false) == nil)
    }

    @Test func expectedConditionWaitsDoNotCreateProblemNotifications() {
        let id = UUID()
        let waiting = PlanRuntimeState(
            planID: id, nextRun: nil, pause: nil,
            health: HealthAssessment(planID: id, lastSuccessfulBackup: nil, reasons: [.noSuccessfulBackup]),
            verification: nil, testRestore: nil, maintenance: nil, issue: .waitingConditions)
        #expect(
            BackupNotificationPolicy.decision(
                plan: waiting, now: .now, lastProblem: nil,
                firstSuccessSent: false) == nil)
    }

    private func state(reasons: [HealthAssessment.Reason], success: Date? = nil) -> PlanRuntimeState {
        let id = UUID()
        return PlanRuntimeState(
            planID: id, nextRun: nil, pause: nil,
            health: HealthAssessment(planID: id, lastSuccessfulBackup: success, reasons: reasons),
            verification: nil, testRestore: nil, maintenance: nil)
    }
}
