import BackupDomain
import BackupEngine
import Foundation
import Testing

@testable import BackupEngine

struct AutomaticBackupRuntimeTests {
    @Test func timeTriggerDrainsProtectedEngineAndWritesHistoryWithoutExplicitPerformNext() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await waitForRuntime { await fixture.monitor.observing && fixture.time.sleeperCount == 1 }
        fixture.time.advance(59)
        #expect(await fixture.history.started.isEmpty)
        fixture.time.advance(1)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        #expect(await fixture.history.finished.first?.outcome == .succeeded)
        #expect(await fixture.history.finished.first?.trigger == .interval(minutes: 1))
        #expect(await fixture.history.finished.first?.sources.count == 2)
        #expect(await fixture.issues.values.isEmpty)
        await runtime.shutdown()
        #expect(await runtime.state == .stopped)
        #expect(await fixture.monitor.closed)
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func mountEvidenceIsDiscardedByStopAndNewMountCanRun() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.onVolumeMount])
        let runtime = try fixture.runtime()
        try await runtime.start()
        await fixture.monitor.send(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        try await runtime.stop(planID: fixture.plan.id)
        fixture.time.advance(60)
        #expect(await fixture.history.started.isEmpty)
        await fixture.monitor.send(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(10)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        #expect(await fixture.history.finished.first?.trigger == .onVolumeMount)
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func transientFailuresRetryThreeTimesAndResetOnNewManualRequest() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .alwaysTransient)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        for (index, seconds) in [60.0, 300, 900].enumerated() {
            try await waitForRuntime {
                await fixture.history.finished.count == index + 1 && fixture.time.sleeperCount == 1
            }
            fixture.time.advance(seconds)
        }
        try await waitForRuntime { await fixture.issues.values == [.backupFailed(planID: fixture.plan.id)] }
        #expect(await fixture.history.finished.count == 4)
        #expect(await fixture.sessions.opens == 4)
        #expect(await fixture.history.finished.allSatisfy { $0.outcome == .failed })
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 5 && fixture.time.sleeperCount == 1 }
        await runtime.shutdown()
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func monitorFailureCancelsActiveRunJoinsCleanupAndDisablesFurtherAdmission() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        await fixture.monitor.fail()
        try await waitForRuntime { await runtime.state == .monitorUnavailable }
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await service.closed)
        #expect(await service.cancellations == 1)
        #expect(await fixture.monitor.closed)
        // Terminal state is committed before the asynchronous issue callback is delivered.
        try await waitForRuntime { await fixture.issues.values == [.monitorUnavailable] }
        #expect(await fixture.issues.values == [.monitorUnavailable])
        await #expect(throws: CancellationError.self) { try await runtime.enqueue(planID: fixture.plan.id) }
        await runtime.shutdown()
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func timedPauseCancelsThenResumesThroughSameAutomaticDrain() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        let deadline = fixture.time.date.addingTimeInterval(60)
        try await runtime.pause(planID: fixture.plan.id, until: deadline)
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await service.closed)
        fixture.time.advance(60)
        try await waitForRuntime { await fixture.history.finished.count == 2 }
        #expect(await fixture.history.finished.last?.outcome == .succeeded)
        #expect(await fixture.sessions.opens == 2)
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func pauseCancelsPendingRetryAndWakeReconcilesTimedPause() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .alwaysTransient)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 1 && fixture.time.sleeperCount == 1 }
        try await runtime.pause(until: fixture.time.date.addingTimeInterval(600))
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(60)
        #expect(await fixture.history.finished.count == 1)
        fixture.time.adjustWallTime(by: 600)
        await fixture.monitor.send(.woke)
        try await waitForRuntime { await runtime.pauseState() == nil }
        #expect(await fixture.history.finished.count == 1)
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 2 && fixture.time.sleeperCount == 1 }
        await runtime.shutdown()
        #expect(fixture.time.sleeperCount == 0)
    }
    @Test func timedPauseRestoresMountTriggersWithoutReplayingPausedEvidence() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.onVolumeMount])
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.pause(planID: fixture.plan.id, until: fixture.time.date.addingTimeInterval(60))
        await fixture.monitor.send(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        fixture.time.advance(60)
        try await waitForRuntime { await runtime.pauseState(planID: fixture.plan.id) == nil }
        try await waitForRuntime { await runtime.eventConfiguration?.plans.count == 1 }
        #expect(await fixture.history.started.isEmpty)
        await fixture.monitor.send(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(10)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        await runtime.shutdown()
    }

    @Test func pauseExpiryRestoresOtherPlanEventsWhileEngineRemainsBusy() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let original = fixture.plan
        let other = try BackupPlan(
            name: "Other", isEnabled: true, repositoryID: original.repositoryID,
            sources: [try BackupSource(path: "/Third", volume: original.sources[0].volume)],
            triggers: [.onVolumeMount], conditions: original.conditions, retention: original.retention,
            excludes: original.excludes, options: original.options, health: original.health)
        try await fixture.store.save(
            BackupConfiguration(repositories: [fixture.base.repository], plans: [original, other]))
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: original.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        try await runtime.pause(planID: other.id, until: fixture.time.date.addingTimeInterval(60))
        fixture.time.advance(60)
        try await waitForRuntime {
            await runtime.eventConfiguration?.plans.contains(where: { $0.id == other.id }) == true
        }
        #expect(await fixture.history.finished.isEmpty)
        await fixture.monitor.send(.volumeMounted(uuid: other.sources[0].volume.uuid))
        // First source still waits for cancellation; the second plan's debounce is independent.
        let events = await runtime.events
        try await waitForRuntime {
            let idle = await events.isIdle
            return fixture.time.sleeperCount >= 1 && !idle
        }
        fixture.time.advance(10)
        try await waitForRuntime { await events.isIdle }
        try await runtime.stop(planID: original.id)
        try await waitForRuntime { await fixture.history.finished.count == 2 }
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await fixture.history.finished.last?.planID == other.id)
        #expect(await fixture.history.finished.last?.outcome == .succeeded)
        await runtime.shutdown()
    }

    @Test func unverifiedSourceAccessSkipsAutomaticRunWithoutOpeningSession() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], sourceAccess: .unknown)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        #expect(await fixture.history.finished.first?.outcome == .skipped)
        #expect(await fixture.sessions.opens == 0)
        #expect(await fixture.issues.values.isEmpty)
        await runtime.shutdown()
    }

    @Test func failureCallbackCanShutdownItsOwnDrainWithoutDeadlock() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .permanentFailure)
        let owner = RuntimeTestOwner()
        let runtime = try fixture.runtime(issue: { issue in
            await fixture.issues.record(issue)
            await owner.shutdown()
        })
        await owner.set(runtime)
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await runtime.state == .stopped }
        #expect(await fixture.monitor.closed)
        #expect(await fixture.issues.values == [.backupFailed(planID: fixture.plan.id)])
        #expect(await fixture.history.finished.first?.outcome == .failed)
        #expect(fixture.time.sleeperCount == 0)
    }

}

private actor RuntimeTestOwner {
    var runtime: AutomaticBackupRuntime<SchedulerTestClock>?
    func set(_ runtime: AutomaticBackupRuntime<SchedulerTestClock>) { self.runtime = runtime }
    func shutdown() async { await runtime?.shutdown() }
}
