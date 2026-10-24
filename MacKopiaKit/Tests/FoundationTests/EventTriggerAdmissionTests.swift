import BackupDomain
import BackupEngine
import Foundation
import SystemIntegration
import Testing

@testable import Persistence

struct EventTriggerAdmissionTests {
    @Test func simulatedMountEntersExistingConfiguredQueueAfterDebounceAndLoginGate() async throws {
        let fixture = try PreflightTestFixture()
        let original = fixture.plan
        let plan = try BackupPlan(
            id: original.id, name: original.name, isEnabled: true, repositoryID: original.repositoryID,
            sources: original.sources, triggers: [.onVolumeMount], conditions: original.conditions,
            retention: original.retention, excludes: original.excludes, options: original.options,
            health: original.health)
        let configuration = try BackupConfiguration(repositories: [fixture.repository], plans: [plan])
        let store = ConfigStore(files: MemoryConfigFiles(), codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(configuration)
        let queue = JobQueue()
        let runner = ConfiguredJobRunner(
            store: store, queue: queue,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.preflight, protection: LocalBackupOperationProtection()))
        let time = SchedulerTestClock()
        let coordinator = EventTriggerCoordinator(
            loginDate: time.date, clock: time, now: { time.date }, runner: runner,
            failed: { _, error in Issue.record(error) })
        await coordinator.replace(configuration: configuration)
        await coordinator.receive(.volumeMounted(uuid: fixture.plan.sources[0].volume.uuid))
        for _ in 0..<10_000 {
            if time.sleeperCount == 1 { break }
            await Task.yield()
        }
        try #require(time.sleeperCount == 1)
        time.advance(59)
        #expect(await queue.takeNext() == nil)
        time.advance(1)
        var job: BackupJob?
        for _ in 0..<10_000 {
            if let next = await queue.takeNext() { job = next; break }
            await Task.yield()
        }
        await coordinator.stop()
        let admitted = try #require(job)
        #expect(admitted.plan == plan)
        #expect(admitted.trigger == .onVolumeMount)
        #expect(admitted.requestedAt == time.date)
        #expect(await queue.complete(admitted))
        #expect(await queue.takeNext() == nil)
        #expect(await fixture.probe.operations.isEmpty)
    }
}
