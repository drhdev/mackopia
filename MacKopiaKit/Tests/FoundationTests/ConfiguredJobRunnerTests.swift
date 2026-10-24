import BackupDomain
import BackupEngine
import Foundation
import Testing

@testable import Persistence

struct ConfiguredJobRunnerTests {
    @Test func requestsRequireLoadedConfigurationEnabledPlanAndConfiguredAutomaticTrigger() async throws {
        let fixture = try PreflightTestFixture()
        let files = MemoryConfigFiles()
        let store = ConfigStore(files: files, codec: try ConfigCodec())
        let runner = runner(fixture, store: store)
        await #expect(throws: ConfigStoreError.notLoaded) {
            try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        }
        _ = try await store.load()
        await #expect(throws: JobAdmissionError.planUnavailable) {
            try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        }
        let automatic = try edited(fixture.plan, triggers: [.onVolumeMount])
        try await store.save(configuration(fixture, plan: automatic))
        _ = try await runner.enqueue(planID: automatic.id, trigger: .manual, requestedAt: .now)
        await #expect(throws: JobAdmissionError.triggerUnavailable) {
            try await runner.enqueue(planID: automatic.id, trigger: .onNetworkReachable, requestedAt: .now)
        }
        try await store.save(configuration(fixture, plan: edited(automatic, enabled: false)))
        await #expect(throws: JobAdmissionError.planDisabled) {
            try await runner.enqueue(planID: automatic.id, trigger: .manual, requestedAt: .now)
        }
        files.state.withLock { $0.unavailable = true }
        _ = try await store.load()
        await #expect(throws: ConfigStoreError.safeMode) {
            try await runner.enqueue(planID: automatic.id, trigger: .manual, requestedAt: .now)
        }
    }

    @Test func queuedPlansRefreshBeforePreflightAndReturnOnlyCoordinatorResults() async throws {
        let fixture = try PreflightTestFixture()
        let store = try await store(fixture)
        let runner = runner(fixture, store: store)
        _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        let changed = try edited(fixture.plan, name: "Changed")
        try await store.save(configuration(fixture, plan: changed))
        let result = try await runner.performNext { plan, repository, sources in
            #expect(plan == changed)
            #expect(repository == fixture.repository)
            #expect(sources == changed.sources)
            return 42
        }
        guard case .completed(let value, _) = result else { Issue.record("Operation did not execute"); return }
        #expect(value == 42)
        let empty = try await runner.performNext { _, _, _ in true }
        #expect(empty == nil)
    }

    @Test func removedDisabledAndReconfiguredQueuedPlansAreRejectedAndReleased() async throws {
        for change in 0..<3 {
            let fixture = try PreflightTestFixture()
            let store = try await store(fixture)
            let queue = JobQueue()
            let runner = runner(fixture, store: store, queue: queue)
            let plan = try edited(fixture.plan, triggers: [.onVolumeMount])
            try await store.save(configuration(fixture, plan: plan))
            let job = try await runner.enqueue(planID: plan.id, trigger: .onVolumeMount, requestedAt: .now)
            switch change {
            case 0: try await store.save(BackupConfiguration())
            case 1: try await store.save(configuration(fixture, plan: edited(plan, enabled: false)))
            default: try await store.save(configuration(fixture, plan: edited(plan, triggers: [.manual])))
            }
            let expected: JobAdmissionError =
                change == 0 ? .planUnavailable : change == 1 ? .planDisabled : .triggerUnavailable
            await #expect(throws: expected) {
                try await runner.performNext { _, _, _ in Issue.record("Invalid plan executed") }
            }
            #expect(await fixture.probe.operations.isEmpty)
            #expect(await queue.complete(job) == false)
            let followUp = try await queue.enqueue(plan: plan, trigger: .manual, requestedAt: .now)
            #expect(await queue.takeNext() == followUp)
        }
    }

    @Test func editsDuringAwaitedProtectionPreventOperation() async throws {
        let fixture = try PreflightTestFixture()
        let store = try await store(fixture)
        let queue = JobQueue()
        let protection = AdmissionProtection(arm: {
            try await store.save(configuration(fixture, plan: edited(fixture.plan, name: "Changed")))
        })
        let runner = runner(fixture, store: store, queue: queue, protection: protection)
        _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        await #expect(throws: JobAdmissionError.configurationChanged) {
            try await runner.performNext { _, _, _ in Issue.record("Stale configuration executed") }
        }
        let followUp = try await queue.enqueue(plan: fixture.plan, trigger: .manual, requestedAt: .now)
        #expect(await queue.takeNext() == followUp)
    }

    @Test func safeModeAfterEnqueueBlocksExecution() async throws {
        let fixture = try PreflightTestFixture()
        let files = MemoryConfigFiles()
        let store = try await store(fixture, files: files)
        let runner = runner(fixture, store: store)
        _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        files.state.withLock { $0.unavailable = true }
        _ = try await store.load()
        await #expect(throws: ConfigStoreError.safeMode) {
            try await runner.performNext { _, _, _ in Issue.record("Safe mode executed") }
        }
        #expect(await fixture.probe.operations.isEmpty)
    }

    @Test func successFailureAndCancellationKeepPlanReservedUntilProtectionCleanup() async throws {
        for outcome in 0..<3 {
            let fixture = try PreflightTestFixture()
            let store = try await store(fixture)
            let queue = JobQueue()
            let cleaning = AdmissionSignal()
            let release = AdmissionSignal()
            let runner = runner(
                fixture, store: store, queue: queue,
                protection: AdmissionProtection(disarm: {
                    await cleaning.signal()
                    await release.wait()
                }))
            _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
            let running = Task {
                try await runner.performNext { _, _, _ in
                    if outcome == 1 { throw BackupOperationError.operationFailed }
                    return 42
                }
            }
            await cleaning.wait()
            let followUp = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
            if outcome == 2 { running.cancel() }
            #expect(await queue.takeNext() == nil)
            await release.signal()
            if outcome == 0 {
                guard case .completed(let value, _) = try await running.value else {
                    Issue.record("Operation did not complete"); continue
                }
                #expect(value == 42)
            } else if outcome == 1 {
                await #expect(throws: BackupOperationError.operationFailed) { try await running.value }
            } else {
                await #expect(throws: CancellationError.self) { try await running.value }
            }
            #expect(await queue.takeNext() == followUp)
        }
    }

    @Test func historyFinalizationKeepsPlanReservedUntilItFinishes() async throws {
        let fixture = try PreflightTestFixture()
        let store = try await store(fixture)
        let queue = JobQueue()
        let runner = runner(fixture, store: store, queue: queue)
        let finalizing = AdmissionSignal()
        let release = AdmissionSignal()
        _ = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        let task = Task {
            try await runner.performNextJob { _, _, _ in
                true
            } finalized: { _, _ in
                await finalizing.signal()
                await release.wait()
            }
        }
        await finalizing.wait()
        let followUp = try await runner.enqueue(planID: fixture.plan.id, trigger: .manual, requestedAt: .now)
        #expect(await queue.takeNext() == nil)
        await release.signal()
        guard case .completed = try await task.value else { Issue.record("Expected completed run"); return }
        #expect(await queue.takeNext() == followUp)
    }

    private func runner(
        _ fixture: PreflightTestFixture, store: ConfigStore, queue: JobQueue = JobQueue(),
        protection: AdmissionProtection = AdmissionProtection()
    ) -> ConfiguredJobRunner {
        ConfiguredJobRunner(
            store: store, queue: queue,
            coordinator: BackupOperationCoordinator(preflight: fixture.preflight, protection: protection))
    }

    private func store(
        _ fixture: PreflightTestFixture, files: MemoryConfigFiles = MemoryConfigFiles()
    ) async throws
        -> ConfigStore
    {
        let store = ConfigStore(files: files, codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(configuration(fixture, plan: fixture.plan))
        return store
    }

    private func configuration(_ fixture: PreflightTestFixture, plan: BackupPlan) throws -> BackupConfiguration {
        try BackupConfiguration(repositories: [fixture.repository], plans: [plan])
    }

    private func edited(
        _ plan: BackupPlan, name: String? = nil, enabled: Bool = true, triggers: [Trigger]? = nil
    ) throws -> BackupPlan {
        try BackupPlan(
            id: plan.id, name: name ?? plan.name, isEnabled: enabled, repositoryID: plan.repositoryID,
            sources: plan.sources, triggers: triggers ?? plan.triggers, conditions: plan.conditions,
            retention: plan.retention, excludes: plan.excludes, options: plan.options, health: plan.health)
    }
}

private struct AdmissionProtection: BackupOperationProtecting {
    var arm: @Sendable () async throws -> Void = {}
    var disarm: @Sendable () async -> Void = {}

    func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository, operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await arm()
        do {
            let result = try await operation()
            await disarm()
            return result
        } catch {
            await disarm()
            throw error
        }
    }
}

private actor AdmissionSignal {
    private var signalled = false
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
