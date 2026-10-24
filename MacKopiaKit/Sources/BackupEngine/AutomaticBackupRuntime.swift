import BackupDomain
import Foundation
import Persistence
import SystemIntegration

/// One monitoring session and one serial engine owner. Shutdown is terminal; create a new runtime
/// after configuration reload. This package boundary does not grant source access or register an agent.
package actor AutomaticBackupRuntime<C: Clock> where C.Duration == Duration {
    package internal(set) var state: AutomaticBackupState = .idle
    let store: ConfigStore
    let queue: JobQueue
    let runner: ConfiguredJobRunner
    let engine: ManualBackupEngine
    let scheduler: Scheduler
    let clock: C
    let now: @Sendable () -> Date
    let loginDate: Date
    let monitor: any SystemEventMonitoring
    let reachability: any DestinationReachabilityChecking
    let calendar: @Sendable () -> Calendar
    let issue: @Sendable (AutomaticBackupIssue) async -> Void
    var configuration: BackupConfiguration?
    var eventConfiguration: BackupConfiguration?
    var observedPauseRevision: UInt64 = 0
    var generation: UInt64 = 0
    var planVersions: [UUID: UInt64] = [:]
    var controlVersion: UInt64 = 0
    var controls: [UUID?: UUID] = [:]
    var shutdownTask: Task<Void, Never>?
    var admissions: [UUID: (UUID, Task<Void, any Error>)] = [:]
    var blockedPlans: Set<UUID> = []
    var blockingAll = false
    var monitorTask: Task<Void, Never>?
    var drainTask: Task<Void, Never>?
    var queueTask: Task<Void, Never>?
    var workRevision: UInt64 = 0
    lazy var events = EventTriggerCoordinator(
        loginDate: loginDate, clock: clock, now: now, reachability: reachability,
        admit: { [weak self] plan, repository, request in
            await AutomaticWorker.$kind.withValue(nil) {
                await self?.admit(request, evidence: (plan, repository), retry: false)
            }
        },
        failed: { [weak self] id, _ in
            await AutomaticWorker.$kind.withValue(nil) { await self?.reportAdmission(id) }
        })
    lazy var retries = BackupRetryCoordinator(
        clock: clock, now: now,
        admit: { [weak self] plan, repository, trigger, date in
            guard let self else { throw CancellationError() }
            try await AutomaticWorker.$kind.withValue(nil) {
                try await self.submit(
                    ScheduledRequest(planID: plan.id, trigger: trigger, requestedAt: date),
                    evidence: (plan, repository), retry: true)
            }
        },
        terminal: { [weak self] job in
            if RetryWorker.id != nil {
                await AutomaticWorker.$kind.withValue(nil) { await self?.reportFailure(job.plan.id) }
            } else {
                await self?.reportFailure(job.plan.id)
            }
        })

    package init(
        store: ConfigStore, coordinator: BackupOperationCoordinator, sessions: any BackupSessionOpening,
        history: any JobHistoryRecording, resolver: TimeMachineExclusionResolver, homeDirectory: String,
        loginDate: Date, clock: C, now: @escaping @Sendable () -> Date = { .now },
        monitor: any SystemEventMonitoring = LocalSystemEventMonitor(),
        reachability: any DestinationReachabilityChecking = TCPReachabilityChecker(),
        calendar: @escaping @Sendable () -> Calendar = { .current },
        jitter: @escaping @Sendable () -> Double = { .random(in: -60...60) },
        issue: @escaping @Sendable (AutomaticBackupIssue) async -> Void
    ) {
        self.store = store
        let queue = JobQueue(clock: clock, now: now)
        self.queue = queue
        let runner = ConfiguredJobRunner(store: store, queue: queue, coordinator: coordinator)
        self.runner = runner
        engine = ManualBackupEngine(
            runner: runner, sessions: sessions, history: history, resolver: resolver,
            homeDirectory: homeDirectory, clock: clock, now: now)
        scheduler = Scheduler(loginDate: loginDate, calendar: calendar(), clock: clock, now: now, jitter: jitter)
        self.loginDate = loginDate
        self.clock = clock
        self.now = now
        self.monitor = monitor
        self.reachability = reachability
        self.calendar = calendar
        self.issue = issue
    }

    /// History anchors are supplied explicitly; no guessed success or crash resumption.
    package func start(lastRuns: [UUID: Date] = [:]) async throws {
        guard state == .idle else { throw SystemMonitoringError.unavailable }
        state = .starting
        generation &+= 1
        let version = generation
        do {
            let configuration = try await store.currentConfiguration()
            try Task.checkCancellation()
            guard state == .starting, generation == version else { throw CancellationError() }
            try await scheduler.replace(plans: configuration.plans, lastRuns: lastRuns)
            await events.replace(configuration: configuration)
            guard state == .starting, generation == version else {
                await events.stop()
                throw CancellationError()
            }
            try Task.checkCancellation()
            self.configuration = configuration
            eventConfiguration = configuration
            state = .running
            await startScheduler()
            try Task.checkCancellation()
            guard state == .running, generation == version else { return }
            let admissions = queue.admissions
            queueTask = Task { [weak self] in
                await AutomaticWorker.$kind.withValue(.queue) {
                    for await pauseRevision in admissions {
                        guard !Task.isCancelled else { break }
                        await self?.queueChanged(pauseRevision)
                    }
                }
            }
            let monitor = monitor
            monitorTask = Task { [weak self] in
                await AutomaticWorker.$kind.withValue(.monitor) {
                    do {
                        try await monitor.observe { [weak self] event in await self?.receive(event) }
                        if !Task.isCancelled { await self?.monitorFailed() }
                    } catch {
                        if !Task.isCancelled { await self?.monitorFailed() }
                    }
                }
            }
        } catch {
            if generation == version, state == .starting || state == .running { await shutdown() }
            throw error
        }
    }

    func startScheduler() async {
        guard state == .running else { return }
        let version = controlVersion
        await scheduler.start { [weak self] request in
            await AutomaticWorker.$kind.withValue(nil) { await self?.scheduled(request, version: version) }
        }
        if state != .running { await scheduler.stop() }
    }

    func scheduled(_ request: ScheduledRequest, version: UInt64) async {
        guard controlVersion == version else { return }
        await admit(request, evidence: nil, retry: false)
    }

    func receive(_ event: SystemEvent) async {
        guard state == .running else { return }
        switch event {
        case .woke, .clockChanged:
            await scheduler.reconcile()
            do { try await queue.reconcilePauses() } catch { await monitorFailed() }
        case .timeZoneChanged: await scheduler.reconcile(calendar: calendar())
        default: break
        }
        guard state == .running else { return }
        await events.receive(event)
    }

    func queueChanged(_ pauseRevision: UInt64) async {
        guard state == .running else { return }
        if observedPauseRevision != pauseRevision {
            observedPauseRevision = pauseRevision
            controlVersion &+= 1
            await refreshEvents(version: controlVersion)
            if state == .running { await startScheduler() }
        }
        workRevision &+= 1
        guard drainTask == nil, state == .running else { return }
        drainTask = Task { [weak self] in
            await AutomaticWorker.$kind.withValue(.drain) { await self?.drain() }
        }
    }

    func drain() async {
        defer { drainTask = nil }
        while state == .running, !Task.isCancelled {
            let version = workRevision
            do {
                let run = try await engine.performNext { [weak self] job, result in
                    await self?.finished(job, result: result)
                }
                if run == nil, workRevision == version { return }
            } catch {
                if Task.isCancelled { return }
                // The completion observer handles the fixed failure event or retry after queue release.
            }
        }
    }

    func finished(_ job: BackupJob, result: Result<JobRun, any Error>) async {
        guard state == .running, !blockingAll, !blockedPlans.contains(job.plan.id) else { return }
        let version = generation
        let planVersion = planVersions[job.plan.id, default: 0]
        switch result {
        case .success: await retries.reset(planID: job.plan.id)
        case .failure(let error):
            guard !(error is CancellationError), !(await queue.isPaused(job.plan.id)) else {
                await retries.reset(planID: job.plan.id)
                return
            }
            do {
                let configuration = try await store.currentConfiguration()
                guard let repository = configuration.repositories.first(where: { $0.id == job.plan.repositoryID })
                else {
                    await reportFailure(job.plan.id)
                    return
                }
                guard current(job.plan.id, generation: version, planVersion: planVersion),
                    !(await queue.isPaused(job.plan.id))
                else { return }
                await retries.failed(job: job, repository: repository, error: error)
            } catch { await reportFailure(job.plan.id) }
        }
    }

    func monitorFailed() async {
        guard state == .running else { return }
        await shutdown(failed: true)
        await issue(.monitorUnavailable)
    }
}

enum AutomaticWorker {
    enum Kind: Sendable { case drain, monitor, queue }
    @TaskLocal static var kind: Kind?
}
