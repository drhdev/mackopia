import BackupDomain
import Foundation
import Testing

@testable import BackupEngine

struct DailyRuntimeTests {
    @Test func explicitCheckFinishesBeforeQueuedBackupAndStopJoinsCancellation() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let probe = DailyWorkProbe()
        let runtime = try fixture.runtime(check: { _ in try await probe.wait() })
        try await runtime.start()
        try await runtime.requestCheck(fixture.plan.id)
        try await waitForRuntime { await probe.started }
        try await runtime.enqueue(planID: fixture.plan.id)
        #expect(await fixture.history.started.isEmpty)
        try await runtime.stop(planID: fixture.plan.id)
        #expect(await probe.cancelled)
        #expect(await fixture.history.started.isEmpty)
        #expect(await runtime.requestedChecks.isEmpty)
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func maintenanceIsSerialAndPauseCancelsItBeforeStartingAnotherBackup() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let probe = DailyWorkProbe()
        let runtime = try fixture.runtime(maintenance: { _ in try await probe.wait() })
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await probe.started }
        #expect(await fixture.history.finished.count == 1)
        try await runtime.enqueue(planID: fixture.plan.id)
        #expect(await fixture.history.started.count == 1)
        try await runtime.pause(planID: fixture.plan.id)
        #expect(await probe.cancelled)
        #expect(await fixture.history.started.count == 1)
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func mutationScopeRejectsActiveBackupWithoutCancellingIt() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let session = try #require(await fixture.sessions.services.first)
        await session.waitUntilUpload()
        await #expect(throws: LocalServiceIssue.busy) {
            try await runtime.withConfigurationChange { Issue.record("Mutation ran during a backup") }
        }
        #expect(await session.cancellations == 0)
        try await runtime.stop(planID: fixture.plan.id)
        #expect(await session.cancellations == 1)
        await runtime.shutdown()
    }
}

private actor DailyWorkProbe {
    private(set) var started = false
    private(set) var cancelled = false
    func wait() async throws {
        started = true
        do { try await Task.sleep(for: .seconds(3600)) } catch { cancelled = true; throw error }
    }
}
