import BackupDomain
import Foundation
import KopiaServer

/// Sequential source execution inside the caller's continuously held repository/volume reservation.
package struct SourceBackupExecutor: Sendable {
    let service: any KopiaBackupServing
    let clock: any Clock<Duration>
    let pollInterval: Duration
    let progress: @Sendable (BackupProgress) async -> Void
    let cancellationFailed: @Sendable () async -> Void

    func backup(
        plan: BackupPlan, source: BackupSource, selector: KopiaSnapshotSource
    ) async throws -> JobRun.SourceResult {
        let before = try await service.snapshotManifests(source: selector)
        guard let snapshots = before.snapshots else { throw BackupOperationError.sourceResponseInvalid }
        let previous = Set(snapshots.compactMap(\.id))
        guard previous.count == snapshots.count, previous.allSatisfy({ !$0.isEmpty }) else {
            throw BackupOperationError.sourceResponseInvalid
        }
        let baseline = try SnapshotPlausibilityGuard.baseline(snapshots)
        if let status = try await status(selector), status.status != "IDLE" {
            throw BackupOperationError.sourceBusy
        }
        try Task.checkCancellation()
        do {
            // Mark the request as possibly active before awaiting: transport failure is not proof of no write.
            try await service.startUpload(source: selector)
            return try await waitForSnapshot(
                plan: plan, source: source, selector: selector, previous: previous, baseline: baseline)
        } catch {
            let service = service
            let clock = clock
            // Cleanup must outlive caller cancellation. The session owner always stops/reaps afterwards,
            // including when this graceful 30-second cancellation cannot be confirmed.
            await Task.detached {
                do {
                    try await cancelAndWait(selector, service: service, clock: clock)
                } catch { await cancellationFailed() }
            }.value
            throw error
        }
    }

    private func waitForSnapshot(
        plan: BackupPlan, source: BackupSource, selector: KopiaSnapshotSource, previous: Set<String>,
        baseline: KopiaSnapshot?
    ) async throws -> JobRun.SourceResult {
        let clock = self.clock
        return try await waitForSnapshot(
            clock: clock, plan: plan, source: source, selector: selector, previous: previous, baseline: baseline)
    }

    private func waitForSnapshot<C: Clock>(
        clock: C, plan: BackupPlan, source: BackupSource, selector: KopiaSnapshotSource, previous: Set<String>,
        baseline: KopiaSnapshot?
    ) async throws -> JobRun.SourceResult where C.Duration == Duration {
        let started = clock.now
        let acknowledgmentDeadline = started.advanced(by: .seconds(30))
        var estimator = BackupProgressEstimator()
        var observedActive = false
        while true {
            try Task.checkCancellation()
            let state = try await status(selector)
            if let upload = state?.upload {
                await progress(
                    estimator.progress(
                        planID: plan.id, sourceID: source.id, upload: upload, elapsed: started.duration(to: clock.now)))
            }
            if state?.status == "IDLE", let last = state?.lastSnapshot, let id = last.id, !previous.contains(id) {
                guard last.incomplete == nil || last.incomplete == "", last.endTime != nil else {
                    throw BackupOperationError.snapshotIncomplete
                }
                guard let entries = try await service.snapshotManifests(source: selector).snapshots else {
                    throw BackupOperationError.snapshotReferenceMissing
                }
                let matches = entries.filter { $0.id == id }
                guard matches.count == 1, let snapshot = matches.first,
                    let rootID = snapshot.rootID, !rootID.isEmpty
                else { throw BackupOperationError.snapshotReferenceMissing }
                guard snapshot.incomplete == nil || snapshot.incomplete == "" else {
                    throw BackupOperationError.snapshotIncomplete
                }
                guard let summary = snapshot.summary, let bytes = summary.size, bytes >= 0,
                    let files = summary.files, files >= 0, let errors = summary.numFailed, errors >= 0,
                    let reportedErrors = last.stats?.errorCount, reportedErrors >= 0,
                    let ignoredErrors = last.stats?.ignoredErrorCount, ignoredErrors >= 0
                else { throw BackupOperationError.sourceResponseInvalid }
                let result = JobRun.SourceResult(
                    sourceID: source.id, snapshotID: id, rootID: rootID, bytes: bytes, files: files,
                    errors: max(errors, reportedErrors), ignoredErrors: ignoredErrors)
                // Finish protection and preserve the result before propagating caller cancellation.
                let guardService = SnapshotPlausibilityGuard(service: service)
                return await Task.detached {
                    await guardService.protect(
                        result: result, snapshot: snapshot, baseline: baseline, source: selector,
                        previousIDs: previous, percent: plan.options.plausibilityDropPercent)
                }.value
            }
            if let state, state.status != "IDLE" {
                guard state.status == "UPLOADING" || state.status == "PENDING" else {
                    throw BackupOperationError.sourceStateUnknown
                }
                observedActive = true
            } else if observedActive || clock.now >= acknowledgmentDeadline {
                // Returning to IDLE without a new complete manifest is never success.
                throw BackupOperationError.snapshotMissing
            }
            try await clock.sleep(for: pollInterval)
        }
    }

    private func status(_ selector: KopiaSnapshotSource) async throws -> KopiaSourceStatus? {
        let result = try await service.sources()
        guard let sources = result.sources else { throw BackupOperationError.operationFailed }
        let matches = sources.filter {
            $0.source?.userName == selector.userName && $0.source?.host == selector.host
                && $0.source?.path == selector.path
        }
        guard matches.count <= 1 else { throw BackupOperationError.operationFailed }
        return matches.first
    }

    private func cancelAndWait<C: Clock>(
        _ selector: KopiaSnapshotSource, service: any KopiaBackupServing, clock: C
    ) async throws where C.Duration == Duration {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await service.cancelUpload(source: selector)
                try await waitUntilIdle(selector, service: service, clock: clock)
            }
            group.addTask {
                try await clock.sleep(for: .seconds(30))
                throw BackupOperationError.operationFailed
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    private func waitUntilIdle<C: Clock>(
        _ selector: KopiaSnapshotSource, service: any KopiaBackupServing, clock: C
    ) async throws where C.Duration == Duration {
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            let all = try await service.sources()
            if all.sources?.contains(where: {
                $0.source?.userName == selector.userName && $0.source?.host == selector.host
                    && $0.source?.path == selector.path && $0.status == "IDLE"
            }) == true {
                return
            }
            try await clock.sleep(for: .seconds(1))
        }
        throw BackupOperationError.operationFailed
    }
}
