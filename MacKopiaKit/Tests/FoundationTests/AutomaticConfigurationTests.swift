import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import BackupEngine
@testable import Persistence

struct AutomaticConfigurationTests {
    @Test func newIntervalTakesEffectWithoutRestartingMonitor() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let runtime = try fixture.runtime()
        try await runtime.start()
        let changed = try copy(fixture.plan, triggers: [.interval(minutes: 2)])
        try await fixture.store.save(
            BackupConfiguration(repositories: [fixture.base.repository], plans: [changed]))
        try await runtime.reloadConfiguration()
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        fixture.time.advance(120)
        try await waitForRuntime { await fixture.history.finished.count == 1 }
        #expect(await fixture.history.finished.first?.trigger == .interval(minutes: 2))
        #expect(await fixture.monitor.observing)
        #expect(await fixture.monitor.closed == false)
        await runtime.shutdown()
        #expect(await fixture.issues.values.isEmpty)
    }

    @Test func changedActivePlanIsCancelledAndNewRequestUsesReplacement() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        try await runtime.enqueue(planID: fixture.plan.id)
        let changed = try copy(fixture.plan, name: "Changed")
        try await fixture.store.save(
            BackupConfiguration(repositories: [fixture.base.repository], plans: [changed]))
        try await runtime.reloadConfiguration()
        #expect(await service.closed)
        #expect(await fixture.history.finished.count == 1)
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await runtime.configuration?.plans == [changed])
        try await runtime.enqueue(planID: changed.id)
        try await waitForRuntime { await fixture.history.finished.count == 2 }
        #expect(await fixture.history.finished.last?.outcome == .succeeded)
        await runtime.shutdown()
    }

    @Test func unchangedActiveWorkAndPauseSurviveReload() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let other = try copy(
            fixture.plan, id: UUID(), name: "Other",
            sources: [
                try BackupSource(path: "/Third", volume: fixture.plan.sources[0].volume)
            ])
        try await fixture.store.save(
            BackupConfiguration(repositories: [fixture.base.repository], plans: [fixture.plan, other]))
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.pause(planID: other.id)
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        let changed = try copy(other, name: "Renamed")
        try await fixture.store.save(
            BackupConfiguration(repositories: [fixture.base.repository], plans: [fixture.plan, changed]))
        try await runtime.reloadConfiguration()
        #expect(await fixture.history.finished.isEmpty)
        #expect(await service.closed == false)
        #expect(await runtime.pauseState(planID: other.id) == .indefinite)
        await runtime.shutdown()
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
    }

    @Test func removedPausedPlanIsPrunedDurablyAndMountEvidenceIsDiscarded() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.onVolumeMount])
        let runtime = try fixture.runtime()
        try await runtime.start()
        await fixture.monitor.send(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        try await waitForRuntime { fixture.time.sleeperCount == 1 }
        // Even a no-op reload must invalidate evidence collected against the previous generation.
        try await runtime.reloadConfiguration()
        #expect(fixture.time.sleeperCount == 0)
        fixture.time.advance(60)
        #expect(await fixture.history.started.isEmpty)
        try await runtime.pause(planID: fixture.plan.id)
        try await fixture.store.save(BackupConfiguration(repositories: [fixture.base.repository], plans: []))
        try await runtime.reloadConfiguration()
        #expect(await runtime.pauseState(planID: fixture.plan.id) == nil)
        #expect(try fixture.store.pauseStore.makeSession().load().isEmpty)
        await #expect(throws: JobAdmissionError.self) { try await runtime.enqueue(planID: fixture.plan.id) }
        await runtime.shutdown()
    }

    @Test func safeModeReloadCancelsActiveWorkAndFailsClosed() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        try fixture.files.withLock { try $0.replace(.primary, with: Data("invalid".utf8)) }
        _ = try await fixture.store.load()
        await #expect(throws: ConfigStoreError.safeMode) { try await runtime.reloadConfiguration() }
        #expect(await runtime.state == .configurationUnavailable)
        #expect(await service.closed)
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await fixture.issues.values == [.configurationUnavailable])
        await #expect(throws: CancellationError.self) { try await runtime.enqueue(planID: fixture.plan.id) }
    }

    @Test(arguments: [false, true])
    func shutdownOrStoreEditDuringReloadCannotPublishStaleConfiguration(shutdown: Bool) async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual])
        let history = ReloadHistory()
        let runtime = try fixture.runtime(historyOverride: history)
        try await runtime.start(lastRuns: [:])
        let reload = Task { try await runtime.reloadConfiguration() }
        try await waitForRuntime { await history.reading }
        await #expect(throws: RepositoryOperationError.repositoryBusy) { try await runtime.pause() }
        await #expect(throws: CancellationError.self) { try await runtime.enqueue(planID: fixture.plan.id) }
        if shutdown {
            await runtime.shutdown()
        } else {
            try await fixture.store.save(BackupConfiguration(repositories: [fixture.base.repository], plans: []))
        }
        await history.release()
        if shutdown {
            await #expect(throws: CancellationError.self) { try await reload.value }
            #expect(await runtime.state == .stopped)
            #expect(await fixture.issues.values.isEmpty)
        } else {
            await #expect(throws: ConfigStoreError.storageChanged) { try await reload.value }
            #expect(await runtime.state == .configurationUnavailable)
        }
        #expect(await fixture.sessions.opens == 0)
        #expect(await fixture.monitor.closed)
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func destinationChangeCancelsWorkEvenWhenPlanIsUnchanged() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.manual], mode: .firstWaits)
        let runtime = try fixture.runtime()
        try await runtime.start()
        try await runtime.enqueue(planID: fixture.plan.id)
        try await waitForRuntime { await fixture.sessions.services.count == 1 }
        let service = try #require(await fixture.sessions.services.first)
        await service.waitUntilUpload()
        let original = fixture.base.repository
        let changed = try Repository(
            id: original.id, name: "Changed destination", kind: original.kind, createdAt: original.createdAt,
            identity: original.identity, secretRef: original.secretRef)
        try await fixture.store.save(BackupConfiguration(repositories: [changed], plans: [fixture.plan]))
        try await runtime.reloadConfiguration()
        #expect(await service.closed)
        #expect(await fixture.history.finished.first?.outcome == .cancelled)
        #expect(await runtime.configuration?.repositories == [changed])
        await runtime.shutdown()
    }

    private func copy(
        _ plan: BackupPlan, id: UUID? = nil, name: String? = nil,
        sources: [BackupSource]? = nil, triggers: [Trigger]? = nil
    ) throws -> BackupPlan {
        try BackupPlan(
            id: id ?? plan.id, name: name ?? plan.name, isEnabled: plan.isEnabled,
            repositoryID: plan.repositoryID, sources: sources ?? plan.sources,
            triggers: triggers ?? plan.triggers, conditions: plan.conditions, retention: plan.retention,
            excludes: plan.excludes, options: plan.options, health: plan.health)
    }
}

private actor ReloadHistory: JobHistoryRecording, JobHistoryScheduleReading {
    var reading = false
    private var continuation: CheckedContinuation<Void, Never>?
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func scheduleAnchors(plans: [BackupPlan], before: Date) async -> [UUID: Date] {
        reading = true
        await withCheckedContinuation { continuation = $0 }
        return [:]
    }
    func release() { continuation?.resume(); continuation = nil }
}
