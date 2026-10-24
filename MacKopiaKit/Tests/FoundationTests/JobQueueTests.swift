import BackupDomain
import BackupEngine
import Foundation
import Testing

struct JobQueueTests {
    @Test func pendingDuplicatesRefreshPlanPreservingRequestAndFIFOPosition() async throws {
        let queue = JobQueue()
        let firstPlan = try plan()
        let original = try await queue.enqueue(plan: firstPlan, trigger: .manual, requestedAt: date(20))
        let other = try await queue.enqueue(plan: plan(), trigger: .manual, requestedAt: date(0))
        let editedPlan = try plan(id: firstPlan.id, name: "Edited")
        let duplicate = try await queue.enqueue(
            plan: editedPlan, trigger: .onVolumeMount, requestedAt: date(10))
        #expect(duplicate.id == original.id)
        #expect(duplicate.trigger == original.trigger)
        #expect(duplicate.requestedAt == original.requestedAt)
        #expect(duplicate.plan == editedPlan)
        #expect(await queue.takeNext() == duplicate)
        #expect(await queue.takeNext() == other)
        #expect(await queue.takeNext() == nil)
    }

    @Test func activeFollowUpWaitsWithoutBlockingOtherPlansAndRejectsStaleCompletion() async throws {
        let queue = JobQueue()
        let firstPlan = try plan()
        let original = try await queue.enqueue(plan: firstPlan, trigger: .manual, requestedAt: date(0))
        #expect(await queue.takeNext() == original)
        let followUp = try await queue.enqueue(plan: firstPlan, trigger: .onVolumeMount, requestedAt: date(1))
        #expect(followUp.id != original.id)
        #expect(await queue.complete(followUp) == false)
        #expect(await queue.takeNext() == nil)
        let duplicate = try await queue.enqueue(plan: firstPlan, trigger: .manual, requestedAt: date(2))
        #expect(duplicate == followUp)
        let other = try await queue.enqueue(plan: plan(), trigger: .manual, requestedAt: date(3))
        #expect(await queue.takeNext() == other)
        #expect(await queue.complete(original))
        #expect(await queue.takeNext() == followUp)
        #expect(await queue.complete(original) == false)
        let third = try await queue.enqueue(plan: firstPlan, trigger: .manual, requestedAt: date(4))
        #expect(await queue.takeNext() == nil)
        #expect(await queue.complete(followUp))
        #expect(await queue.takeNext() == third)
        #expect(await queue.complete(other))
        #expect(await queue.complete(third))
        #expect(await queue.takeNext() == nil)
    }

    @Test func concurrentAdmissionsAndConsumersProduceOneActiveJobPerPlan() async throws {
        let queue = JobQueue()
        let plans = try (0..<8).map { _ in try plan() }
        let requestDate = date(0)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for plan in plans {
                for _ in 0..<16 {
                    group.addTask { try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: requestDate) }
                }
            }
            try await group.waitForAll()
        }
        let jobs = await withTaskGroup(of: BackupJob?.self, returning: [BackupJob].self) { group in
            for _ in 0..<32 { group.addTask { await queue.takeNext() } }
            var jobs: [BackupJob] = []
            for await job in group { if let job { jobs.append(job) } }
            return jobs
        }
        #expect(jobs.count == plans.count)
        #expect(Set(jobs.map(\.plan.id)) == Set(plans.map(\.id)))
        #expect(Set(jobs.map(\.id)).count == plans.count)
        for job in jobs { #expect(await queue.complete(job)) }
        #expect(await queue.takeNext() == nil)
    }

    @Test func invalidRequestsDoNotOccupyQueueOrCoalesceAwayValidation() async throws {
        let queue = JobQueue()
        let plan = try plan()
        let valid = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: date(0))
        await #expect(throws: DomainValidationError.invalidPlan) {
            try await queue.enqueue(plan: plan, trigger: .interval(minutes: 0), requestedAt: date(0))
        }
        for interval: TimeInterval in [.infinity, -.infinity, .nan] {
            await #expect(throws: DomainValidationError.invalidPlan) {
                try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: date(interval))
            }
        }
        #expect(await queue.takeNext() == valid)
        #expect(await queue.complete(valid))
        #expect(await queue.takeNext() == nil)
    }

    private func date(_ interval: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: interval) }

    private func plan(id: UUID = UUID(), name: String = "Test") throws -> BackupPlan {
        try BackupPlan(
            id: id, name: name, isEnabled: true, repositoryID: UUID(),
            sources: [
                BackupSource(
                    path: "/Source",
                    volume: VolumeIdentity(
                        uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
            ], triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: true),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: true, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }
}
