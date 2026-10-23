import BackupDomain
import BackupEngine
import Foundation
import Testing

struct BackupOperationTests {
    @Test func successRechecksUnderProtectionAndPassesOnlyAvailableSourcesInPlanOrder() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(scenario: .init(missingSources: ["/Source"]), gate: gate)
        let events = OperationEvents()
        let protection = TestProtection(events: events)
        let coordinator = BackupOperationCoordinator(preflight: fixture.preflight, protection: protection)
        let result = try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { sources in
            #expect(sources.map(\.id) == [fixture.plan.sources[1].id])
            #expect(await events.values == ["armed"])
            await #expect(throws: RepositoryOperationError.repositoryBusy) {
                try await gate.withOperation(repositoryID: fixture.repository.id) { Issue.record("Gate was released") }
            }
            let operations = await fixture.probe.operations
            #expect(operations.filter { $0 == "binary" }.count == 2)
            #expect(Array(operations.suffix(3)) == ["directory:/Destination", "directory:/Source", "directory:/Other"])
            await events.append("operation")
            return sources.count
        }
        guard case .completed(let value, let report) = result else { Issue.record("Operation did not run"); return }
        #expect(value == 1)
        #expect(report.outcome == .checksPassed)
        #expect(await events.values == ["armed", "operation", "disarmed"])
        #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
    }

    @Test func defaultProtectionNeverInvokesOperationAndReleasesReservation() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(gate: gate)
        let coordinator = BackupOperationCoordinator(preflight: fixture.preflight)
        await #expect(throws: BackupOperationError.protectionUnavailable) {
            try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                Issue.record("Unprotected operation entered")
            }
        }
        #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
    }

    @Test func initialBlockAndSkipNeverArmMonitoringOrExecute() async throws {
        for scenario in [PreflightTestScenario(missingPassword: true), .init(missingSources: ["/Source", "/Other"])] {
            let fixture = try PreflightTestFixture(scenario: scenario)
            let events = OperationEvents()
            let coordinator = BackupOperationCoordinator(
                preflight: fixture.preflight, protection: TestProtection(events: events))
            let result = try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                Issue.record("Blocked/skipped operation entered")
            }
            guard case .notStarted(let report) = result else { Issue.record("Unexpected completion"); continue }
            #expect(report.outcome != .checksPassed)
            #expect(await events.values.isEmpty)
        }
    }

    @Test func changesWhileArmingAreReevaluatedAndDoNotUsePriorReport() async throws {
        let fixture = try PreflightTestFixture()
        let events = OperationEvents()
        let protection = TestProtection(
            events: events,
            arm: {
                await fixture.probe.updateScenario(.init(sourceAccess: .denied))
            })
        let coordinator = BackupOperationCoordinator(preflight: fixture.preflight, protection: protection)
        let result = try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
            Issue.record("Stale report authorized operation")
        }
        guard case .notStarted(let report) = result else { Issue.record("Unexpected completion"); return }
        #expect(report.checks.last?.issue == .sourceAccessDenied)
        #expect(await events.values == ["armed", "disarmed"])
    }

    @Test func finalIdentityChangesStopBeforeOperation() async throws {
        for path in ["/Source", "/Destination"] {
            let gate = try RepositoryOperationGate()
            let fixture = try PreflightTestFixture(gate: gate)
            let preflight = BackupPreflight(
                prerequisites: BackupPrerequisitePreflight(binary: fixture.probe, secrets: fixture.probe), gate: gate,
                paths: BackupPathPreflight(inspector: fixture.probe),
                destination: FilesystemDestinationPreflight(inspector: fixture.probe),
                repositoryAccess: fixture.probe, sourceAccess: fixture.probe,
                environment: ChangingEnvironment(probe: fixture.probe, unavailablePath: path))
            let events = OperationEvents()
            let coordinator = BackupOperationCoordinator(
                preflight: preflight, protection: TestProtection(events: events))
            do {
                _ = try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                    Issue.record("Changed identity reached operation")
                }
                Issue.record("Identity change was accepted")
            } catch {
                #expect(
                    path == "/Source"
                        ? error as? BackupOperationError == .identitiesChanged
                        : error as? BackupPreflightError == .destinationUnavailable)
            }
            #expect(await events.values == ["armed", "disarmed"])
            #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
        }
    }

    @Test func cancellationKeepsGateAndMonitoringUntilOperationCleanupCompletes() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(gate: gate)
        let events = OperationEvents()
        let entered = LifecycleSignal()
        let finishCleanup = LifecycleSignal()
        let coordinator = BackupOperationCoordinator(
            preflight: fixture.preflight, protection: TestProtection(events: events))
        let running = Task {
            try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                await entered.signal()
                await finishCleanup.wait()
                await events.append("reaped")
                try Task.checkCancellation()
            }
        }
        await entered.wait()
        running.cancel()
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: fixture.repository.id) {
                Issue.record("Cleanup lost reservation")
            }
        }
        #expect(await events.values == ["armed"])
        await finishCleanup.signal()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await events.values == ["armed", "reaped", "disarmed"])
        #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
    }

    @Test func cancellationDuringMonitoringCleanupStillKeepsReservationAndPropagates() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(gate: gate)
        let events = OperationEvents()
        let cleaning = LifecycleSignal()
        let release = LifecycleSignal()
        let protection = TestProtection(
            events: events,
            disarm: {
                await cleaning.signal()
                await release.wait()
            })
        let coordinator = BackupOperationCoordinator(preflight: fixture.preflight, protection: protection)
        let running = Task {
            try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in 42 }
        }
        await cleaning.wait()
        running.cancel()
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: fixture.repository.id) {
                Issue.record("Monitor cleanup lost gate")
            }
        }
        #expect(await events.values == ["armed"])
        await release.signal()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(await events.values == ["armed", "disarmed"])
        #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
    }

    @Test func arbitraryOperationErrorsAreSanitizedAfterProtectionCleanup() async throws {
        let fixture = try PreflightTestFixture()
        let events = OperationEvents()
        let coordinator = BackupOperationCoordinator(
            preflight: fixture.preflight, protection: TestProtection(events: events))
        await #expect(throws: BackupOperationError.operationFailed) {
            try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                throw NSError(domain: "private-marker", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-data"])
            }
        }
        #expect(await events.values == ["armed", "disarmed"])
        #expect(!String(reflecting: BackupOperationError.operationFailed).contains("private-data"))
    }

    @Test func occupiedGateAndCancellationNeverEnterProtection() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(gate: gate)
        let events = OperationEvents()
        let coordinator = BackupOperationCoordinator(
            preflight: fixture.preflight, protection: TestProtection(events: events))
        _ = try await gate.withOperation(repositoryID: fixture.repository.id) {
            await #expect(throws: RepositoryOperationError.repositoryBusy) {
                try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                    Issue.record("Busy entry")
                }
            }
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                    Issue.record("Cancelled entry")
                }
            }
        }
        await cancelled.value
        #expect(await events.values.isEmpty)
        #expect(await fixture.probe.operations.isEmpty)
    }
}

private struct TestProtection: BackupOperationProtecting {
    let events: OperationEvents
    var arm: @Sendable () async -> Void = {}
    var disarm: @Sendable () async -> Void = {}
    func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository, operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        await events.append("armed")
        await arm()
        do {
            let result = try await operation()
            await disarm()
            await events.append("disarmed")
            return result
        } catch {
            await disarm()
            await events.append("disarmed")
            throw error
        }
    }
}

private actor ChangingEnvironment: RunEnvironmentSampling {
    let probe: PreflightTestProbe
    let unavailablePath: String
    var count = 0
    init(probe: PreflightTestProbe, unavailablePath: String) {
        self.probe = probe
        self.unavailablePath = unavailablePath
    }
    func sample() async throws -> RunEnvironment {
        count += 1
        let result = try await probe.sample()
        if count == 2 { await probe.updateScenario(.init(missingSources: [unavailablePath])) }
        return result
    }
}

private actor OperationEvents {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor LifecycleSignal {
    var signalled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
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
