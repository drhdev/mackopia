import BackupDomain
import BackupEngine
import Foundation
import Testing

@testable import Persistence

struct ConfiguredJobControlTests {
    @Test func pauseWaitsForFinalizationAndEarlyResumeCannotStartAnotherRun() async throws {
        let fixture = try PreflightTestFixture()
        let (runner, queue) = try await control(fixture)
        let entered = ControlSignal()
        let finalizing = ControlSignal()
        let release = ControlSignal()
        let pauseReturned = ControlSignal()
        let original = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        let running = Task {
            try await runner.performNextJob { _, _, _ in
                await entered.signal()
                try await ContinuousClock().sleep(for: .seconds(60))
            } finalized: { _, result in
                guard case .failure(let error) = result, error is CancellationError else {
                    Issue.record("Expected cancellation before finalization"); return
                }
                await finalizing.signal()
                await release.wait()
            }
        }
        await entered.wait()
        let pausing = Task {
            await queue.pause(planID: fixture.plan.id)
            await pauseReturned.signal()
        }
        await finalizing.wait()
        #expect(await pauseReturned.isSignalled == false)
        #expect(await queue.takeNext() == nil)
        try await queue.resume(planID: fixture.plan.id, requestedAt: .now)
        #expect(await queue.takeNext() == nil)
        await release.signal()
        await pausing.value
        await #expect(throws: CancellationError.self) { try await running.value }
        let resumed = try #require(await queue.takeNext())
        #expect(resumed.id != original.id)
        #expect(await queue.complete(original) == false)
        #expect(await queue.complete(resumed))
        #expect(await queue.takeNext() == nil)
    }

    @Test func pauseDuringSuccessfulFinalizationDoesNotRepeatCompletedWork() async throws {
        let fixture = try PreflightTestFixture()
        let (runner, queue) = try await control(fixture)
        let finalizing = ControlSignal()
        let release = ControlSignal()
        _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        let running = Task {
            try await runner.performNextJob { _, _, _ in
                true
            } finalized: { _, _ in
                await finalizing.signal()
                await release.wait()
            }
        }
        await finalizing.wait()
        let pausing = Task { await queue.pause(planID: fixture.plan.id) }
        for _ in 0..<10_000 {
            if await queue.isPaused(fixture.plan.id) { break }
            await Task.yield()
        }
        try #require(await queue.isPaused(fixture.plan.id))
        try await queue.resume(planID: fixture.plan.id, requestedAt: .now)
        await release.signal()
        await pausing.value
        guard case .completed = try await running.value else { Issue.record("Expected success"); return }
        #expect(await queue.takeNext() == nil)
    }

    @Test func cancellationDuringHistoryAdmissionRetainsResumeIntent() async throws {
        let fixture = try PreflightTestFixture()
        let (runner, queue) = try await control(fixture)
        let admitted = ControlSignal()
        let release = ControlSignal()
        let original = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        let running = Task {
            try await runner.performNextJob(
                admitted: { _ in
                    await admitted.signal()
                    await release.wait()
                    try Task.checkCancellation()
                }, operation: { _, _, _ in Issue.record("Cancelled admission executed") },
                finalized: { _, _ in Issue.record("Unrecorded admission was finalized") })
        }
        await admitted.wait()
        let pausing = Task { await queue.pause(planID: fixture.plan.id) }
        for _ in 0..<10_000 {
            if await queue.isPaused(fixture.plan.id) { break }
            await Task.yield()
        }
        try #require(await queue.isPaused(fixture.plan.id))
        await release.signal()
        await pausing.value
        await #expect(throws: CancellationError.self) { try await running.value }
        try await queue.resume(planID: fixture.plan.id, requestedAt: .now)
        let resumed = try #require(await queue.takeNext())
        #expect(resumed.id != original.id)
        #expect(await queue.complete(resumed))
        #expect(await fixture.probe.operations.isEmpty)
    }

    private func control(_ fixture: PreflightTestFixture) async throws -> (ConfiguredJobRunner, JobQueue) {
        let store = ConfigStore(files: MemoryConfigFiles(), codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [fixture.plan]))
        let queue = JobQueue()
        return (
            ConfiguredJobRunner(
                store: store, queue: queue,
                coordinator: BackupOperationCoordinator(
                    preflight: fixture.preflight, protection: ManualTestProtection())), queue
        )
    }
}

private actor ControlSignal {
    private var signalled = false
    var isSignalled: Bool { signalled }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
