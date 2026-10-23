import BackupDomain
import BackupEngine
import Foundation
import KopiaCLI
import SystemIntegration
import Testing

struct BackupPreflightTests {
    @Test func localChecksFollowSpecifiedOrderAndFreshlyObserveEveryRun() async throws {
        let fixture = try PreflightTestFixture()
        let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
        #expect(report.outcome == .checksPassed)
        #expect(
            report.checks.map(\.step) == [
                .binary, .backupPassword, .destinationIdentity, .destinationAccess, .destinationCapacity,
                .sourceIdentity, .sourceAccess, .runConditions, .repositoryExclusion,
            ])
        #expect(report.checks.allSatisfy { $0.status == .passed && $0.issue == nil && $0.action == nil })
        #expect(report.sources == fixture.plan.sources.map { .ready(sourceID: $0.id) })
        let expected = [
            "binary", "secret", "directory:/Destination", "filesystem", "directory:/Source", "directory:/Other",
            "sourceAccess", "environment",
        ]
        #expect(await fixture.probe.operations == expected)
        #expect(await fixture.probe.accessSourceIDs == fixture.plan.sources.map(\.id))
        #expect(!String(reflecting: report).contains(fixture.plan.sources[0].id.uuidString))
        #expect(try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository) == report)
        #expect(await fixture.probe.operations == expected + expected)
    }

    @Test func failuresStopAtTheirStepAndNeverExposeUnderlyingErrors() async throws {
        for (operation, step, expectedCount) in [
            ("binary", BackupPreflightCheck.Step.binary, 1), ("secret", .backupPassword, 2),
            ("directory:/Destination", .destinationIdentity, 3), ("filesystem", .destinationAccess, 4),
            ("sourceAccess", .sourceAccess, 7), ("environment", .runConditions, 8),
        ] {
            let fixture = try PreflightTestFixture(scenario: .init(failAt: operation))
            let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            #expect(report.outcome == .blocked)
            #expect(report.checks.last?.step == step)
            #expect(report.checks.last?.status == .blocked)
            #expect(report.checks.last?.action != nil)
            #expect(await fixture.probe.operations.count == expectedCount)
            #expect(!String(reflecting: report.checks).contains("private-marker"))
        }
    }

    @Test func missingPasswordHasNextActionAndDoesNotInspectDestination() async throws {
        let fixture = try PreflightTestFixture(scenario: .init(missingPassword: true))
        let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
        #expect(report.outcome == .blocked)
        #expect(report.checks.last?.issue == .configuration(.backupPasswordRequired))
        #expect(report.checks.last?.action == .enterBackupPassword)
        #expect(await fixture.probe.operations == ["binary", "secret"])
    }

    @Test func capacityWarningsContinueButInsufficientSpaceStopsBeforeSources() async throws {
        for (bytes, outcome) in [
            (Int64(999_999_999), BackupPreflightReport.Outcome.blocked), (1_000_000_000, .checksPassed),
        ] {
            let fixture = try PreflightTestFixture(scenario: .init(availableBytes: bytes))
            let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            #expect(report.outcome == outcome)
            let capacity = try #require(report.checks.first { $0.step == .destinationCapacity })
            #expect(capacity.status == (outcome == .blocked ? .blocked : .warning))
            #expect(capacity.action == .freeDestinationSpace)
            if outcome == .blocked {
                #expect(await fixture.probe.operations == ["binary", "secret", "directory:/Destination", "filesystem"])
            }
        }
    }

    @Test func missingSourcesNeverReachAccessProbeAndAllMissingSkipsRun() async throws {
        for missing in [Set(["/Source"]), Set(["/Source", "/Other"])] {
            let fixture = try PreflightTestFixture(scenario: .init(missingSources: missing))
            let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            if missing.count == 2 {
                #expect(report.outcome == .skipped)
                #expect(report.checks.last?.issue == .noAvailableSources)
                #expect(await fixture.probe.accessSourceIDs.isEmpty)
                #expect(!(await fixture.probe.operations).contains("environment"))
            } else {
                #expect(report.outcome == .checksPassed)
                #expect(report.checks.first { $0.step == .sourceIdentity }?.issue == .sourcesSkipped)
                #expect(await fixture.probe.accessSourceIDs == [fixture.plan.sources[1].id])
            }
            #expect(report.sources.first == .skipped(sourceID: fixture.plan.sources[0].id, reason: .unavailable))
        }
    }

    @Test func unverifiedSourceAccessAndRemoteAccessAreBlocking() async throws {
        for status in [PreflightAccessStatus.unknown, .denied] {
            let local = try PreflightTestFixture(scenario: .init(sourceAccess: status))
            let localReport = try await local.preflight.evaluate(plan: local.plan, repository: local.repository)
            #expect(localReport.outcome == .blocked)
            #expect(localReport.checks.last?.issue == (status == .unknown ? .sourceAccessUnknown : .sourceAccessDenied))
            #expect(localReport.checks.last?.action == .checkSourceAccess)
            #expect(!(await local.probe.operations).contains("environment"))
            let remote = try PreflightTestFixture(scenario: .init(repositoryAccess: status), remote: true)
            let remoteReport = try await remote.preflight.evaluate(plan: remote.plan, repository: remote.repository)
            #expect(remoteReport.outcome == .blocked)
            #expect(remoteReport.checks.last?.step == .destinationAccess)
            #expect(remoteReport.checks.last?.action == .checkDestinationAccess)
            #expect(await remote.probe.operations == ["binary", "secret", "remote"])
        }
        for remote in [false, true] {
            let fixture = try PreflightTestFixture(remote: remote, useUnknownAdapters: true)
            let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            #expect(report.outcome == .blocked)
            #expect(report.checks.last?.issue == (remote ? .destinationAccessUnknown : .sourceAccessUnknown))
        }
    }

    @Test func verifiedRemoteAccessDoesNotPretendToKnowFilesystemCapacity() async throws {
        let fixture = try PreflightTestFixture(remote: true)
        let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
        #expect(report.outcome == .checksPassed)
        let capacity = try #require(report.checks.first { $0.step == .destinationCapacity })
        #expect(capacity.status == .skipped && capacity.issue == nil)
        #expect(
            await fixture.probe.operations == [
                "binary", "secret", "remote", "directory:/Source", "directory:/Other", "sourceAccess", "environment",
            ])
    }

    @Test func unmetConditionsSkipRatherThanGrantPermission() async throws {
        let fixture = try PreflightTestFixture(scenario: .init(expensiveNetwork: true))
        let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
        #expect(report.outcome == .skipped)
        #expect(report.checks.last?.issue == .conditions(.expensiveNetwork))
        #expect(report.checks.last?.action == .reviewRunConditions)
    }

    @Test func mismatchedConfigurationAndCancelledCallNeverAccessDependencies() async throws {
        let fixture = try PreflightTestFixture()
        let other = try PreflightTestFixture()
        let report = try await fixture.preflight.evaluate(plan: fixture.plan, repository: other.repository)
        #expect(report.outcome == .blocked)
        #expect(report.checks.last?.issue == .configuration(.repositoryMismatch))
        let cancelled = Task<Void, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            }
        }
        await cancelled.value
        #expect(await fixture.probe.operations.isEmpty)
    }

    @Test func cancellationAtEveryObservationPropagatesAndReleasesReservation() async throws {
        for operation in [
            "binary", "secret", "directory:/Destination", "filesystem", "directory:/Source", "sourceAccess",
            "environment", "remote",
        ] {
            let gate = try RepositoryOperationGate()
            let fixture = try PreflightTestFixture(
                scenario: .init(cancelAt: operation), remote: operation == "remote", gate: gate)
            let task = Task<Void, Never> {
                await #expect(throws: CancellationError.self) {
                    try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
                }
            }
            await task.value
            #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
        }
    }

    @Test func occupiedRepositoryAndGlobalLimitStopBeforeAnyObservation() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture(gate: gate)
        for id in [fixture.repository.id, UUID()] {
            let report = try await gate.withOperation(repositoryID: id) {
                try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository)
            }
            #expect(report.outcome == .blocked)
            #expect(report.checks.count == 1)
            #expect(report.checks.last?.step == .repositoryExclusion)
            #expect(
                report.checks.last?.issue
                    == .operation(id == fixture.repository.id ? .repositoryBusy : .concurrencyLimitReached))
            #expect(report.checks.last?.action == .waitForOperation)
        }
        #expect(await fixture.probe.operations.isEmpty)
        #expect(
            try await fixture.preflight.evaluate(plan: fixture.plan, repository: fixture.repository).outcome
                == .checksPassed)
    }

    @Test func reservationRemainsHeldDuringAsynchronousAccessChecks() async throws {
        let gate = try RepositoryOperationGate()
        let fixture = try PreflightTestFixture()
        let preflight = BackupPreflight(
            prerequisites: BackupPrerequisitePreflight(binary: fixture.probe, secrets: fixture.probe), gate: gate,
            paths: BackupPathPreflight(inspector: fixture.probe),
            destination: FilesystemDestinationPreflight(inspector: fixture.probe),
            sourceAccess: ReservationCheckingSourceAccess(gate: gate, repositoryID: fixture.repository.id),
            environment: fixture.probe)
        #expect(
            try await preflight.evaluate(plan: fixture.plan, repository: fixture.repository).outcome == .checksPassed)
        #expect(try await gate.withOperation(repositoryID: fixture.repository.id) { true })
    }
}

private struct ReservationCheckingSourceAccess: SourceAccessChecking {
    let gate: RepositoryOperationGate
    let repositoryID: UUID

    func checkAccess(to sources: [BackupSource]) async throws -> PreflightAccessStatus {
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: repositoryID) {
                Issue.record("Reservation released during check")
            }
        }
        return .verified
    }
}
