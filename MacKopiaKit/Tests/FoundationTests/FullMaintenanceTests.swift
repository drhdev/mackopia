import BackupDomain
import BackupEngine
import Foundation
import Persistence
import Testing

@testable import KopiaCLI

struct FullMaintenanceTests {
    @Test(arguments: ["due", "foreign", "missing", "disabled", "future"])
    func freshOwnerAndScheduleGateExecution(state: String) async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = FullMaintenanceProbe(identity: fixture.base.repository.identity, state: state)
        let coordinator = coordinator(fixture, probe)
        let result = try await coordinator.runDueFull(planID: fixture.plan.id)
        #expect(await probe.runs == (state == "due" ? 1 : 0))
        #expect((result == .completed) == (state == "due"))
        #expect(await probe.reads == 1)
        if state == "due" {
            await probe.setForeignOwner()
            #expect(try await coordinator.runDueFull(planID: fixture.plan.id) == .skipped(.foreignOwner))
            #expect(await probe.runs == 1)
        }
    }

    @Test func unavailablePreflightNeverExecutesAndReadOnlyInspectionStaysReadOnly() async throws {
        let denied = try await AutomaticRuntimeFixture(sourceAccess: .denied)
        let deniedProbe = FullMaintenanceProbe(identity: denied.base.repository.identity)
        #expect(try await coordinator(denied, deniedProbe).runDueFull(planID: denied.plan.id) == nil)
        #expect(await deniedProbe.reads == 0)
        #expect(await deniedProbe.runs == 0)
        let fixture = try await AutomaticRuntimeFixture()
        let probe = FullMaintenanceProbe(identity: fixture.base.repository.identity)
        #expect(try await coordinator(fixture, probe).inspect(planID: fixture.plan.id) == .due)
        #expect(await probe.runs == 0)
    }

    @Test(arguments: [false, true])
    func configurationChangesRejectExecutionOrCompletion(duringRun: Bool) async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = FullMaintenanceProbe(
            identity: fixture.base.repository.identity, hold: duringRun ? .run : .read)
        let coordinator = coordinator(fixture, probe)
        let task = Task { try await coordinator.runDueFull(planID: fixture.plan.id) }
        try await waitForRuntime { await probe.waiting }
        try await fixture.store.save(BackupConfiguration(repositories: [fixture.base.repository], plans: []))
        await probe.release()
        await #expect(throws: JobAdmissionError.configurationChanged) { try await task.value }
        #expect(await probe.runs == (duringRun ? 1 : 0))
    }

    @Test func cancellationRetainsReservationUntilMaintenanceCleanup() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = FullMaintenanceProbe(identity: fixture.base.repository.identity, hold: .cancel)
        let coordinator = coordinator(fixture, probe)
        let task = Task { try await coordinator.runDueFull(planID: fixture.plan.id) }
        try await waitForRuntime { await probe.runs == 1 }
        task.cancel()
        try await waitForRuntime { await probe.waiting }
        let blocked = try await fixture.base.preflight.evaluate(plan: fixture.plan, repository: fixture.base.repository)
        #expect(blocked.outcome == .blocked)
        await probe.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        let released = try await fixture.base.preflight.evaluate(
            plan: fixture.plan, repository: fixture.base.repository)
        #expect(released.outcome == .checksPassed)
    }

    @Test func executionFailureIsSanitizedAndReservationReleased() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let probe = FullMaintenanceProbe(identity: fixture.base.repository.identity, hold: .failure)
        await #expect(throws: BackupOperationError.operationFailed) {
            try await coordinator(fixture, probe).runDueFull(planID: fixture.plan.id)
        }
        let released = try await fixture.base.preflight.evaluate(
            plan: fixture.plan, repository: fixture.base.repository)
        #expect(released.outcome == .checksPassed)
    }

    @Test func commandPreservesSafetyDefaultsAndIsolatedEnvironment() async throws {
        let process = VerifyProcessFixture(output: "private-marker")
        try await run(process)
        let request = try #require(await process.requests.first)
        #expect(request.arguments.suffix(3) == ["maintenance", "run", "--full"])
        #expect(!request.arguments.contains { $0.contains("safety") || $0.contains("force") })
        #expect(request.arguments.contains { $0.hasPrefix("--config-file=/tmp/maintenance-home/Library/") })
        #expect(request.arguments.contains { $0.hasPrefix("--log-dir=/tmp/maintenance-home/Library/") })
        #expect(request.environment["KOPIA_CACHE_DIRECTORY"]?.hasPrefix("/tmp/maintenance-home/Library/") == true)
        #expect(request.environment["KOPIA_PASSWORD"] == "private-test-marker")
        #expect(!request.arguments.contains { $0.contains("private-test-marker") })
        #expect(request.timeout == .seconds(6 * 60 * 60) && request.lowPriority)
        #expect(request.outputLimit == 4 * 1024 * 1024)
        await #expect(throws: KopiaProcessError.commandFailed(exitCode: 7)) {
            try await run(VerifyProcessFixture(code: 7, output: "private-marker"))
        }
    }

    private func run(_ process: VerifyProcessFixture) async throws {
        try await KopiaMaintenanceRunner(process: process).runFull(
            executable: URL(fileURLWithPath: "/tmp/test-kopia"),
            paths: KopiaRepositoryPaths(
                repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/tmp/maintenance-home")),
            temporaryDirectory: URL(fileURLWithPath: "/tmp"), user: "test-user",
            backupPassword: "private-test-marker", lowPriority: true)
    }

    private func coordinator(
        _ fixture: AutomaticRuntimeFixture, _ probe: FullMaintenanceProbe
    ) -> MaintenanceCoordinator {
        MaintenanceCoordinator(
            store: fixture.store,
            coordinator: BackupOperationCoordinator(
                preflight: fixture.base.preflight, protection: ManualTestProtection()),
            inspector: probe, runner: probe, now: { fixture.time.date })
    }
}

private actor FullMaintenanceProbe: MaintenanceInspecting, MaintenanceRunning {
    enum Hold { case read, run, cancel, failure }
    let identity: SnapshotIdentity
    var state: String
    let hold: Hold?
    var reads = 0
    var runs = 0
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(identity: SnapshotIdentity, state: String = "due", hold: Hold? = nil) {
        self.identity = identity; self.state = state; self.hold = hold
    }

    func inspect(repository: Repository, lowPriority: Bool) async throws -> KopiaMaintenanceInfo {
        reads += 1
        if hold == .read { await wait() }
        let owner =
            state == "missing"
            ? "" : state == "foreign" ? "other@host" : identity.overrideUser + "@" + identity.overrideHost
        return try KopiaMaintenanceInfo(
            data: Data(
                maintenanceJSON(
                    owner: owner, enabled: state != "disabled",
                    next: state == "future" ? "2099-01-01T00:00:00Z" : "0001-01-01T00:00:00Z"
                ).utf8))
    }

    func runFull(repository: Repository, lowPriority: Bool) async throws {
        runs += 1
        if hold == .failure { throw NSError(domain: "private-marker", code: 1) }
        if hold == .run { await wait() }
        if hold == .cancel {
            do { try await ContinuousClock().sleep(for: .seconds(60)) } catch {
                await wait()
                throw CancellationError()
            }
        }
    }

    func setForeignOwner() { state = "foreign" }
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
