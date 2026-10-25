import BackupDomain
import Foundation
import KopiaCLI
import Persistence
import SystemIntegration

/// Explicit verification of the last successful run; scheduling and automatic admission are separate.
package actor SnapshotVerificationEngine {
    private let store: ConfigStore
    private let coordinator: BackupOperationCoordinator
    private let verifier: any SnapshotVerifying
    private let restorer: (any SnapshotTestRestoring)?
    private let history: any JobHistoryHealthReading & VerificationHistoryRecording
    private let sleep: any SleepPreventing
    private let now: @Sendable () -> Date
    private var active = false

    package init(
        store: ConfigStore, coordinator: BackupOperationCoordinator, verifier: any SnapshotVerifying,
        history: any JobHistoryHealthReading & VerificationHistoryRecording,
        sleep: any SleepPreventing = LocalSleepPreventer(),
        restorer: (any SnapshotTestRestoring)? = nil, now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.coordinator = coordinator
        self.verifier = verifier
        self.restorer = restorer
        self.history = history
        self.sleep = sleep
        self.now = now
    }

    /// Nil means protected preflight declined the attempt. A cancelled process creates no trust evidence.
    /// A failed command is recorded before its sanitized error is returned; callers must also surface storage errors.
    package func verify(
        planID: UUID, filesPercent: Int = 1, validFor: Duration = .seconds(7 * 24 * 60 * 60)
    ) async throws -> VerificationResult? {
        try await execute(planID: planID, filesPercent: filesPercent, validFor: validFor, kind: .snapshotVerify)
    }

    /// An inconclusive sample leaves existing evidence unchanged. Scheduling is owned by the caller.
    package func testRestore(
        planID: UUID, validFor: Duration = .seconds(30 * 24 * 60 * 60)
    ) async throws -> VerificationResult? {
        guard restorer != nil else { throw BackupOperationError.operationFailed }
        return try await execute(planID: planID, filesPercent: 1, validFor: validFor, kind: .testRestore)
    }

    private func execute(
        planID: UUID, filesPercent: Int, validFor: Duration, kind: VerificationResult.Kind
    ) async throws -> VerificationResult? {
        guard !active else { throw RepositoryOperationError.repositoryBusy }
        guard (1...100).contains(filesPercent), validFor > .zero, validFor <= .seconds(31 * 24 * 60 * 60) else {
            throw ConfigStoreError.invalidConfiguration
        }
        active = true
        defer { active = false }
        try Task.checkCancellation()
        let configuration = try await store.currentConfiguration()
        guard let plan = configuration.plans.first(where: { $0.id == planID }) else {
            throw JobAdmissionError.planUnavailable
        }
        guard plan.isEnabled else { throw JobAdmissionError.planDisabled }
        guard let repository = configuration.repositories.first(where: { $0.id == plan.repositoryID }) else {
            throw JobAdmissionError.repositoryUnavailable
        }
        guard repository.kind.isIntegratedBackend else { throw BackupOperationError.operationFailed }
        let attempt = VerificationAttempt()
        let history = history
        let verifier = verifier
        let restorer = restorer
        let store = store
        let sleep = sleep
        let now = now
        do {
            let execution = try await coordinator.perform(plan: plan, repository: repository) { sources in
                guard sources.count == plan.sources.count else { throw BackupOperationError.snapshotMissing }
                let date = now()
                guard Self.validDate(date) else { throw ConfigStoreError.invalidConfiguration }
                let evidence = try await history.healthHistory(
                    planID: planID, repositoryID: repository.id, before: date)
                guard let run = evidence.latestSuccess,
                    run.planID == plan.id, run.repositoryID == repository.id,
                    run.outcome == .succeeded || run.outcome == .succeededWithWarnings,
                    run.sources.count == sources.count,
                    Set(run.sources.map(\.sourceID)) == Set(sources.map(\.id))
                else { throw BackupOperationError.snapshotMissing }
                // Validate persisted identifiers before resolving secrets or launching any process.
                _ = try KopiaSnapshotVerification(
                    snapshotIDs: run.sources.map(\.snapshotID), filesPercent: filesPercent)
                guard try await store.currentConfiguration() == configuration else {
                    throw JobAdmissionError.configurationChanged
                }
                try Task.checkCancellation()
                let assertion = try sleep.acquire()
                defer { assertion.release() }
                await attempt.begin(at: date)
                let conclusive: Bool
                switch kind {
                case .snapshotVerify:
                    try await verifier.verify(
                        repository: repository, snapshotIDs: run.sources.map(\.snapshotID),
                        filesPercent: filesPercent, lowPriority: plan.options.lowPriority)
                    conclusive = true
                case .testRestore:
                    guard let restorer else { throw BackupOperationError.operationFailed }
                    conclusive = try await restorer.testRestore(
                        repository: repository, sources: sources, run: run, lowPriority: plan.options.lowPriority)
                }
                await attempt.finish(at: now())
                return conclusive
            }
            guard case .completed(let conclusive, _) = execution, conclusive else { return nil }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let startedAt = await attempt.startedAt {
                _ = try await record(
                    plan: plan, startedAt: startedAt, validFor: validFor, kind: kind, filesPercent: filesPercent,
                    outcome: .failed)
            }
            throw error
        }
        try Task.checkCancellation()
        guard try await store.currentConfiguration() == configuration else {
            throw JobAdmissionError.configurationChanged
        }
        guard let startedAt = await attempt.startedAt else { throw BackupOperationError.operationFailed }
        return try await record(
            plan: plan, startedAt: startedAt, endedAt: await attempt.endedAt,
            validFor: validFor, kind: kind, filesPercent: filesPercent, outcome: .succeeded)
    }

    private func record(
        plan: BackupPlan, startedAt: Date, endedAt: Date? = nil,
        validFor: Duration, kind: VerificationResult.Kind, filesPercent: Int, outcome: VerificationResult.Outcome
    ) async throws -> VerificationResult {
        // Timestamp actual command completion, before the reservation is released. Delayed cleanup
        // or persistence must not make an older success supersede a later failed check.
        let date = endedAt ?? now()
        guard Self.validDate(date) else { throw ConfigStoreError.invalidConfiguration }
        let end = max(date, startedAt)
        let components = validFor.components
        let due = end.addingTimeInterval(Double(components.seconds) + Double(components.attoseconds) / 1e18)
        let result = VerificationResult(
            planID: plan.id, repositoryID: plan.repositoryID, kind: kind,
            startedAt: startedAt, endedAt: end, dueAt: due, outcome: outcome,
            filesPercent: kind == .snapshotVerify ? filesPercent : nil)
        if outcome == .succeeded { try Task.checkCancellation() }
        let history = history
        // Persistence must finish even if cancellation arrives after command cleanup.
        try await Task.detached { try await history.recordVerification(result) }.value
        return result
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite && date >= .distantPast && date <= .distantFuture
    }
}

private actor VerificationAttempt {
    private(set) var startedAt: Date?
    private(set) var endedAt: Date?
    func begin(at date: Date) { startedAt = date }
    func finish(at date: Date) { endedAt = date }
}
