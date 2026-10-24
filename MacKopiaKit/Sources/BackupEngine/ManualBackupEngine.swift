import BackupDomain
import Foundation
import KopiaServer
import Persistence

package enum ManualBackupStage: Sendable, Equatable {
    case connecting, synchronizing(sourceID: UUID), uploading(sourceID: UUID), stopping
}

/// Explicit manual execution only; the agent later exposes this boundary through validated XPC.
package actor ManualBackupEngine {
    private let runner: ConfiguredJobRunner
    private let sessions: any BackupSessionOpening
    private let history: any JobHistoryRecording
    private let resolver: TimeMachineExclusionResolver
    private let homeDirectory: String
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let progress: @Sendable (BackupProgress) async -> Void
    private let stageChanged: @Sendable (ManualBackupStage) async -> Void
    private var active = false

    package init(
        runner: ConfiguredJobRunner, sessions: any BackupSessionOpening, history: any JobHistoryRecording,
        resolver: TimeMachineExclusionResolver, homeDirectory: String,
        clock: any Clock<Duration> = ContinuousClock(), now: @escaping @Sendable () -> Date = { .now },
        progress: @escaping @Sendable (BackupProgress) async -> Void = { _ in },
        stageChanged: @escaping @Sendable (ManualBackupStage) async -> Void = { _ in }
    ) {
        self.runner = runner
        self.sessions = sessions
        self.history = history
        self.resolver = resolver
        self.homeDirectory = homeDirectory
        self.clock = clock
        self.now = now
        self.progress = progress
        self.stageChanged = stageChanged
    }

    @discardableResult
    package func enqueue(planID: UUID) async throws -> BackupJob {
        try await runner.enqueue(planID: planID, trigger: .manual, requestedAt: now())
    }

    /// Caller cancellation stops the current source and skips the rest; no automatic resumption.
    /// History writes run outside cancellation and finish before the queue releases the run identity.
    package func performNext() async throws -> JobRun? {
        guard !active else { throw RepositoryOperationError.repositoryBusy }
        active = true
        defer { active = false }
        let record = ManualRunRecord(now: now)
        let sessions = sessions
        let history = history
        let resolver = resolver
        let home = homeDirectory
        let clock = clock
        let progress = progress
        let stageChanged = stageChanged
        _ = try await runner.performNextJob(
            admitted: { job in
                let run = await record.begin(job)
                try await history.begin(run)
            },
            operation: { job, repository, sources in
                guard case .filesystem = repository.kind else { throw BackupOperationError.operationFailed }
                guard job.plan.options.parallelism == nil, job.plan.options.uploadLimitMbps == nil,
                    !job.plan.options.ejectVolumeAfterBackup
                else { throw BackupOperationError.unsupportedOptions }
                await stageChanged(.connecting)
                let session = try await sessions.open(repository: repository, options: job.plan.options)
                do {
                    let status = try await session.service.repositoryStatus()
                    let identity = try await session.service.sources()
                    guard status.connected == true, status.storage == "filesystem",
                        identity.localUsername == repository.identity.overrideUser,
                        identity.localHost == repository.identity.overrideHost
                    else { throw BackupOperationError.operationFailed }
                    let synchronizer = SourcePolicySynchronizer(service: session.service, timeMachineResolver: resolver)
                    // Validate every source policy before the first upload. Each is checked afresh again
                    // just before upload, because an earlier source can take longer than resolver freshness.
                    for source in sources {
                        await stageChanged(.synchronizing(sourceID: source.id))
                        _ = try await synchronizer.synchronize(
                            plan: job.plan, source: source, identity: repository.identity, homeDirectory: home)
                    }
                    let executor = SourceBackupExecutor(
                        service: session.service, clock: clock, pollInterval: .seconds(1), progress: progress,
                        cancellationFailed: { await record.cancellationUnconfirmed() })
                    for source in sources {
                        try Task.checkCancellation()
                        _ = try await synchronizer.synchronize(
                            plan: job.plan, source: source, identity: repository.identity, homeDirectory: home)
                        let selector = try KopiaSnapshotSource(
                            userName: repository.identity.overrideUser, host: repository.identity.overrideHost,
                            path: source.path)
                        await stageChanged(.uploading(sourceID: source.id))
                        let result = try await executor.backup(plan: job.plan, source: source, selector: selector)
                        await record.append(result)
                    }
                } catch {
                    let cleanup = await Task.detached { try await session.close() }.result
                    if case .failure = cleanup { await record.cleanupFailed() }
                    throw error
                }
                await stageChanged(.stopping)
                do { try await Task.detached { try await session.close() }.value } catch {
                    await record.cleanupFailed()
                    throw BackupOperationError.operationFailed
                }
                return true
            },
            finalized: { job, result in
                let run = await record.finish(job: job, result: result)
                try await Task.detached { try await history.finish(run) }.value
            })
        return await record.completed
    }
}

private actor ManualRunRecord {
    let now: @Sendable () -> Date
    private var startedAt = Date.distantPast
    private var results: [JobRun.SourceResult] = []
    private var cleanupIssue = false
    private var cancellationIssue = false
    private(set) var completed: JobRun?

    init(now: @escaping @Sendable () -> Date) { self.now = now }

    func begin(_ job: BackupJob) -> JobRun {
        startedAt = now()
        return run(job, outcome: .running, issues: [])
    }

    func append(_ result: JobRun.SourceResult) { results.append(result) }
    func cleanupFailed() { cleanupIssue = true }
    func cancellationUnconfirmed() { cancellationIssue = true }

    func finish(job: BackupJob, result: Result<BackupOperationResult<Bool>, any Error>) -> JobRun {
        var issues: [JobRun.Issue] = []
        let outcome: JobRun.Outcome
        switch result {
        case .success(.notStarted):
            outcome = .skipped
            issues.append(.preflight)
        case .success(.completed(_, let report)):
            if report.sources.contains(where: { if case .skipped = $0 { true } else { false } }) {
                issues.append(.missingSource)
            }
            if results.contains(where: { $0.errors > 0 || $0.ignoredErrors > 0 }) { issues.append(.fileErrors) }
            outcome = issues.isEmpty ? .succeeded : .succeededWithWarnings
        case .failure(let error):
            outcome = error is CancellationError ? .cancelled : .failed
            issues.append(error as? BackupOperationError == .snapshotIncomplete ? .incompleteSnapshot : .operation)
        }
        if cancellationIssue { issues.append(.cancellationUnconfirmed) }
        if cleanupIssue { issues.append(.cleanup) }
        let value = run(job, outcome: outcome, issues: issues)
        completed = value
        return value
    }

    private func run(_ job: BackupJob, outcome: JobRun.Outcome, issues: [JobRun.Issue]) -> JobRun {
        JobRun(
            id: job.id, planID: job.plan.id, repositoryID: job.plan.repositoryID, trigger: job.trigger,
            startedAt: startedAt, endedAt: max(startedAt, now()), outcome: outcome, sources: results, issues: issues)
    }
}
