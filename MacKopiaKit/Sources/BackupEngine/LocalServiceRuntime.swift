import BackupDomain
import Foundation
import KopiaCLI
import Persistence
import SystemIntegration

extension LocalBackupService {
    func startRuntime() async throws {
        let binary = try KopiaBinaryVerifier(
            executable: executable, paths: KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: home),
            temporaryDirectory: temporary, expectedVersion: version)
        let coordinator = BackupOperationCoordinator(
            preflight: BackupPreflight(
                prerequisites: BackupPrerequisitePreflight(binary: binary, secrets: secrets), gate: gate,
                repositoryAccess: S3RepositoryAccess(
                    executable: executable, home: home, temporary: temporary, secrets: secrets),
                sourceAccess: sourceAccess), protection: protection)
        let verification = SnapshotVerificationEngine(
            store: store, coordinator: coordinator,
            verifier: FilesystemSnapshotVerification(
                executable: executable, homeDirectory: home, temporaryDirectory: temporary,
                user: NSUserName(), secrets: secrets), history: history,
            restorer: FilesystemTestRestore(
                executable: executable, homeDirectory: home, temporaryDirectory: temporary,
                user: NSUserName(), secrets: secrets), now: now)
        let maintenanceAdapter = FilesystemMaintenanceInspection(
            executable: executable, homeDirectory: home, temporaryDirectory: temporary,
            user: NSUserName(), secrets: secrets)
        let maintenance = MaintenanceCoordinator(
            store: store, coordinator: coordinator, inspector: maintenanceAdapter, runner: maintenanceAdapter, now: now)
        let store = store
        let gate = gate
        let history = history
        let now = now
        let runtime = AutomaticBackupRuntime(
            store: store, coordinator: coordinator,
            sessions: FilesystemBackupSessions(
                executable: executable, homeDirectory: home, temporaryDirectory: temporary,
                user: NSUserName(), secrets: secrets), history: history,
            resolver: try TimeMachineExclusionResolver(), homeDirectory: home.path,
            loginDate: loginDate, clock: runtimeClock, executionClock: clock, now: now, monitor: monitor,
            verification: AutomaticSnapshotVerification(engine: verification, history: history, now: now),
            testRestore: AutomaticTestRestore(engine: verification, history: history, now: now),
            check: { id in
                guard try await verification.verify(planID: id) != nil else {
                    throw LocalServiceIssue.verificationFailed
                }
            },
            maintenance: { run in
                do {
                    if try await maintenance.runDueFull(planID: run.planID) == .completed {
                        try await history.recordMaintenance(
                            MaintenanceResult(
                                repositoryID: run.repositoryID, endedAt: now(), outcome: .succeeded))
                    }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    try await history.recordMaintenance(
                        MaintenanceResult(
                            repositoryID: run.repositoryID, endedAt: now(), outcome: .failed))
                    throw error
                }
                do {
                    let config = try await store.currentConfiguration()
                    if let plan = config.plans.first(where: { $0.id == run.planID }),
                        plan.options.ejectVolumeAfterBackup,
                        let repo = config.repositories.first(where: { $0.id == plan.repositoryID }),
                        case .filesystem(let path, let volume) = repo.kind, let volume
                    {
                        try await gate.withOperation(repositoryID: repo.id) {
                            guard try await store.currentConfiguration() == config else {
                                throw JobAdmissionError.configurationChanged
                            }
                            try await LocalVolumeEjector().eject(path: path, volume: volume)
                        }
                    }
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    throw LocalServiceIssue.destination
                }
            },
            progress: { [weak self] in await self?.received($0) },
            activity: { [weak self] in await self?.activity($0) },
            preflightObserved: { [weak self] id, report in await self?.declined(id, report: report) },
            changed: { [weak self] in await self?.changed() },
            issue: { [weak self] in await self?.runtimeIssue($0) })
        self.runtime = runtime
        do { try await runtime.start() } catch {
            issue = .automationUnavailable; changed(); throw LocalServiceIssue.automationUnavailable
        }
    }

    func declined(_ planID: UUID, report: BackupPreflightReport) {
        if report.checks.contains(where: { $0.step == .destinationCapacity }) {
            if report.checks.contains(where: { $0.issue == .lowDestinationSpace }) {
                lowSpacePlans.insert(planID)
            } else {
                lowSpacePlans.remove(planID)
            }
        }
        guard report.outcome != .checksPassed else { changed(); return }
        let failure: LocalServiceIssue
        if report.checks.contains(where: { $0.action == .reviewRunConditions }) {
            failure = .waitingConditions
        } else if report.checks.contains(where: { $0.action == .checkSourceAccess }) {
            failure = .permissions
        } else if report.checks.contains(where: { $0.action == .checkKeychain || $0.action == .enterBackupPassword }) {
            failure = .keychain
        } else {
            failure = .destination
        }
        planIssues[planID] = failure
        if failure != .waitingConditions { issue = failure }
        changed()
    }

    func runtimeIssue(_ failure: AutomaticBackupIssue) {
        let id: UUID?
        switch failure {
        case .configurationUnavailable: issue = .safeMode; id = nil
        case .controlStateUnavailable, .monitorUnavailable: issue = .automationUnavailable; id = nil
        case .verificationFailed(let plan), .testRestoreFailed(let plan): issue = .verificationFailed; id = plan
        case .maintenanceFailed(let plan): issue = .maintenanceFailed; id = plan
        case .ejectionFailed(let plan): issue = .destination; id = plan
        case .backupFailed(let plan), .admissionRejected(let plan): issue = .backupFailed; id = plan
        case .suspiciousSnapshot(let plan, _): issue = .backupFailed; id = plan
        }
        if let id { planIssues[id] = issue }
        changed()
    }

    func runtimeProjection() async throws -> [PlanRuntimeState] {
        guard let runtime, let configuration else { return [] }
        var result: [PlanRuntimeState] = []
        for plan in configuration.plans {
            let restore = try await history.latestVerification(
                planID: plan.id, repositoryID: plan.repositoryID, kind: .testRestore, before: now())
            let maintenance = try await history.latestMaintenance(repositoryID: plan.repositoryID, before: now())
            var observations = HealthObservations()
            observations.testRestoreFailed = restore?.outcome == .failed
            observations.maintenanceFailed = maintenance?.outcome == .failed
            observations.destinationNearlyFull = lowSpacePlans.contains(plan.id)
            if await runtime.state != .running { observations.blockers.insert(.backgroundServiceDisabled) }
            if planIssues[plan.id] == .permissions { observations.blockers.insert(.fullDiskAccessMissing) }
            if planIssues[plan.id] == .keychain { observations.blockers.insert(.passwordMissing) }
            result.append(
                try await PlanRuntimeState(
                    planID: plan.id, nextRun: runtime.scheduler.nextRunDate(planID: plan.id),
                    pause: runtime.pauseState(planID: plan.id),
                    health: runtime.health(planID: plan.id, observations: observations),
                    verification: history.latestVerification(
                        planID: plan.id, repositoryID: plan.repositoryID, kind: .snapshotVerify, before: now()),
                    testRestore: restore, maintenance: maintenance, issue: planIssues[plan.id]))
        }
        return result
    }

    public func restartAutomation() async throws {
        guard !stopped, !mutating, restoreTask == nil, configuration != nil else { throw LocalServiceIssue.unavailable }
        guard active == nil else { throw LocalServiceIssue.busy }
        mutating = true
        defer { mutating = false; changed() }
        await runtime?.shutdown()
        issue = nil
        try await startRuntime()
    }

    public func verify(_ planID: UUID) async throws {
        guard !stopped, !mutating, restoreTask == nil, let runtime else { throw LocalServiceIssue.unavailable }
        try await runtime.requestCheck(planID)
        changed()
    }

    public func pause(planID: UUID? = nil, until: Date? = nil) async throws {
        guard !stopped, !mutating, restoreTask == nil, let runtime else { throw LocalServiceIssue.unavailable }
        try await runtime.pause(planID: planID, until: until)
        changed()
    }

    public func resume(planID: UUID? = nil) async throws {
        guard !stopped, !mutating, restoreTask == nil, let runtime else { throw LocalServiceIssue.unavailable }
        try await runtime.resume(planID: planID)
        changed()
    }
}

extension AutomaticBackupRuntime {
    func currentPlanID() async -> UUID? {
        let active = await queue.activeJobs.values.first?.plan.id
        let pending = await queue.pending.first?.plan.id
        return active ?? checkingPlanID ?? postBackupTask?.planID ?? pending ?? requestedChecks.first
    }
}
