import BackupDomain
import BackupEngine
import Foundation
import KopiaCLI
import Persistence
import Testing

struct MaintenanceCoordinatorTests {
    @Test func protectedInspectionUsesStableRepositoryIdentity() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = MaintenanceProbe(owner: fixture.base.repository.identity)
        let coordinator = makeCoordinator(fixture, probe)
        #expect(try await coordinator.inspect(planID: fixture.plan.id) == .due)
        #expect(await probe.calls == 1)
        #expect(await probe.repositoryID == fixture.base.repository.id)
    }

    @Test func deniedPreflightAndUnknownPlansNeverReadRepository() async throws {
        let fixture = try await AutomaticRuntimeFixture(sourceAccess: .denied)
        let probe = MaintenanceProbe(owner: fixture.base.repository.identity)
        let coordinator = makeCoordinator(fixture, probe)
        #expect(try await coordinator.inspect(planID: fixture.plan.id) == nil)
        await #expect(throws: JobAdmissionError.planUnavailable) { try await coordinator.inspect(planID: UUID()) }
        #expect(await probe.calls == 0)
    }

    @Test func cancellationKeepsReservationUntilProcessCleanup() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = MaintenanceProbe(owner: fixture.base.repository.identity, mode: .wait)
        let coordinator = makeCoordinator(fixture, probe)
        let task = Task { try await coordinator.inspect(planID: fixture.plan.id) }
        try await waitForRuntime { await probe.calls == 1 }
        task.cancel()
        try await waitForRuntime { await probe.cleaning }
        let report = try await fixture.base.preflight.evaluate(plan: fixture.plan, repository: fixture.base.repository)
        #expect(report.outcome == .blocked)
        await probe.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let released = try await fixture.base.preflight.evaluate(
            plan: fixture.plan, repository: fixture.base.repository)
        #expect(released.outcome == .checksPassed)
    }

    @Test func configurationChangeDiscardsObservationAndAdapterErrorsAreSanitized() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = MaintenanceProbe(owner: fixture.base.repository.identity, mode: .hold)
        let coordinator = makeCoordinator(fixture, probe)
        let task = Task { try await coordinator.inspect(planID: fixture.plan.id) }
        try await waitForRuntime { await probe.calls == 1 }
        try await fixture.store.save(BackupConfiguration(repositories: [fixture.base.repository], plans: []))
        await probe.release()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await task.value }

        let other = try await AutomaticRuntimeFixture()
        let failed = MaintenanceProbe(owner: other.base.repository.identity, mode: .failure)
        await #expect(throws: BackupOperationError.operationFailed) {
            try await makeCoordinator(other, failed).inspect(planID: other.plan.id)
        }
    }

    private func makeCoordinator(
        _ fixture: AutomaticRuntimeFixture, _ inspector: any MaintenanceInspecting
    ) -> MaintenanceCoordinator {
        MaintenanceCoordinator(
            store: fixture.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.preflight, protection: ManualTestProtection()),
            inspector: inspector, now: { fixture.time.date })
    }
}

private actor MaintenanceProbe: MaintenanceInspecting {
    enum Mode { case success, failure, wait, hold }
    let owner: SnapshotIdentity
    let mode: Mode
    var calls = 0
    var repositoryID: UUID?
    var cleaning = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(owner: SnapshotIdentity, mode: Mode = .success) { self.owner = owner; self.mode = mode }

    func inspect(repository: Repository, lowPriority: Bool) async throws -> KopiaMaintenanceInfo {
        calls += 1
        repositoryID = repository.id
        if mode == .failure { throw NSError(domain: "private-marker", code: 1) }
        if mode == .wait {
            do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                cleaning = true
                await withCheckedContinuation { continuation = $0 }
                throw CancellationError()
            }
        }
        if mode == .hold { await withCheckedContinuation { continuation = $0 } }
        return try KopiaMaintenanceInfo(
            data: Data(maintenanceJSON(owner: owner.overrideUser + "@" + owner.overrideHost).utf8))
    }

    func release() { continuation?.resume(); continuation = nil }
}
