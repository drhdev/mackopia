import BackupDomain
import BackupEngine
import Foundation
import Testing

struct JobQueueControlTests {
    @Test func overlappingPauseScopesHoldPendingAndRejectAllNewTriggers() async throws {
        let queue = JobQueue()
        let a = try PreflightTestFixture().plan
        let b = try PreflightTestFixture().plan
        let first = try await queue.enqueue(plan: a, trigger: .manual, requestedAt: .now)
        let second = try await queue.enqueue(plan: b, trigger: .manual, requestedAt: .now)
        await queue.pause(planID: a.id)
        await #expect(throws: JobAdmissionError.planPaused) {
            try await queue.enqueue(plan: a, trigger: .onVolumeMount, requestedAt: .now)
        }
        await queue.pause()
        #expect(await queue.takeNext() == nil)
        try await queue.resume(planID: a.id, requestedAt: .now)
        #expect(await queue.isPaused(a.id))
        #expect(await queue.takeNext() == nil)
        await queue.pause(planID: a.id)
        try await queue.resume(requestedAt: .now)
        #expect(await queue.takeNext() == second)
        #expect(await queue.takeNext() == nil)
        try await queue.resume(planID: a.id, requestedAt: .now)
        #expect(await queue.takeNext() == first)
        #expect(await queue.complete(first))
        #expect(await queue.complete(second))
    }

    @Test func stopDropsPendingAndResumeIntentButAllowsNextOrdinaryTrigger() async throws {
        let queue = JobQueue()
        let plan = try PreflightTestFixture().plan
        let original = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
        #expect(await queue.takeNext() == original)
        _ = try await queue.enqueue(plan: plan, trigger: .onVolumeMount, requestedAt: .now)
        await queue.pause(planID: plan.id)
        await queue.stop(planID: plan.id)
        #expect(await queue.complete(original, wasCancelled: true))
        try await queue.resume(planID: plan.id, requestedAt: .now)
        #expect(await queue.takeNext() == nil)
        let next = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
        #expect(await queue.takeNext() == next)
        #expect(next.id != original.id)
    }

    @Test func earlyResumeCannotReleaseActiveIdentityAndCoalescesInterruptedFollowUp() async throws {
        let queue = JobQueue()
        let plan = try PreflightTestFixture().plan
        let original = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
        #expect(await queue.takeNext() == original)
        let followUp = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
        await queue.pause(planID: plan.id)
        try await queue.resume(planID: plan.id, requestedAt: .now)
        #expect(await queue.takeNext() == nil)
        #expect(await queue.complete(original, wasCancelled: true))
        let resumed = try #require(await queue.takeNext())
        #expect(resumed.id == followUp.id)
        #expect(resumed.id != original.id)
        #expect(await queue.complete(resumed))
        try await queue.resume(planID: plan.id, requestedAt: .now)
        #expect(await queue.takeNext() == nil)
    }

    @Test func invalidResumeDatePreservesPauseAndPendingWork() async throws {
        let queue = JobQueue()
        let plan = try PreflightTestFixture().plan
        _ = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
        await queue.pause()
        await #expect(throws: DomainValidationError.invalidPlan) {
            try await queue.resume(requestedAt: Date(timeIntervalSinceReferenceDate: .nan))
        }
        #expect(await queue.isPaused(plan.id))
        #expect(await queue.takeNext() == nil)
        try await queue.resume(requestedAt: .now)
        #expect(await queue.takeNext() != nil)
    }
}
