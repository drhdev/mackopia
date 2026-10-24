import BackupDomain
import Foundation
import SystemIntegration

/// Maps system hints to configuration-bound queue admissions. It never starts an engine operation.
package actor EventTriggerCoordinator<C: Clock> where C.Duration == Duration {
    package typealias Admission = @Sendable (BackupPlan, Repository, ScheduledRequest) async throws -> Void
    private struct MountRequest {
        let plan: BackupPlan
        let repository: Repository
        let version: UInt64
        var evidence: [String: C.Instant]
    }

    private let clock: C
    private let now: @Sendable () -> Date
    private let loginReady: C.Instant
    private let reachability: any DestinationReachabilityChecking
    private let admit: Admission
    private let failed: @Sendable (UUID, any Error) async -> Void
    private var configuration: BackupConfiguration?
    private var running = false
    private var revision: UInt64 = 0
    private var mountVersion: UInt64 = 0
    private var networkVersion: UInt64 = 0
    private var pending: [UUID: MountRequest] = [:]
    private var presentVolumes: Set<String> = []
    private var lastNetwork: SystemNetworkObservation?
    private var suppressedPlans: Set<UUID> = []
    private var planVersions: [UUID: UInt64] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var mountTaskID: UUID?
    private var networkTaskID: UUID?

    var isIdle: Bool { tasks.isEmpty }

    package init(
        loginDate: Date, clock: C, now: @escaping @Sendable () -> Date = { .now },
        reachability: any DestinationReachabilityChecking = TCPReachabilityChecker(),
        admit: @escaping Admission, failed: @escaping @Sendable (UUID, any Error) async -> Void
    ) {
        self.clock = clock
        self.now = now
        let delay = loginDate.addingTimeInterval(60).timeIntervalSince(now())
        loginReady = clock.now.advanced(by: .seconds(delay.isFinite ? max(0, delay) : 60))
        self.reachability = reachability
        self.admit = admit
        self.failed = failed
    }

    package init(
        loginDate: Date, clock: C, now: @escaping @Sendable () -> Date = { .now },
        reachability: any DestinationReachabilityChecking = TCPReachabilityChecker(), runner: ConfiguredJobRunner,
        failed: @escaping @Sendable (UUID, any Error) async -> Void
    ) {
        self.init(
            loginDate: loginDate, clock: clock, now: now, reachability: reachability,
            admit: { plan, repository, request in
                try await runner.enqueue(
                    plan: plan, repository: repository, trigger: request.trigger, requestedAt: request.requestedAt)
            }, failed: failed)
    }

    deinit { for task in tasks.values { task.cancel() } }

    /// Reconfiguration discards old event evidence and joins cancelled probes before accepting new events.
    package func replace(configuration: BackupConfiguration) async {
        revision &+= 1
        let version = revision
        running = false
        pending.removeAll()
        presentVolumes.removeAll()
        suppressedPlans.removeAll()
        planVersions.removeAll()
        lastNetwork = nil
        await cancelAll()
        guard revision == version else { return }
        self.configuration = configuration
        running = true
    }

    package func stop() async {
        revision &+= 1
        running = false
        configuration = nil
        pending.removeAll()
        presentVolumes.removeAll()
        suppressedPlans.removeAll()
        planVersions.removeAll()
        lastNetwork = nil
        await cancelAll()
    }

    /// Invalidate only this plan's evidence. Other plans retain their absolute debounce deadlines;
    /// shared TCP probes may finish, but a changed plan version can never authorize stale admission.
    package func setSuppressed(planID: UUID, _ value: Bool) async {
        guard suppressedPlans.contains(planID) != value else { return }
        if value { suppressedPlans.insert(planID) } else { suppressedPlans.remove(planID) }
        planVersions[planID, default: 0] &+= 1
        pending.removeValue(forKey: planID)
        await restartMountTimer()
    }

    package func receive(_ event: SystemEvent) async {
        guard running, let configuration else { return }
        switch event {
        case .volumeMounted(let value):
            guard let uuid = DomainValidation.volumeUUID(value)?.uuidString else { return }
            presentVolumes.insert(uuid)
            let deadline = clock.now.advanced(by: .seconds(10))
            for plan in configuration.plans where plan.isEnabled && plan.triggers.contains(.onVolumeMount) {
                guard !suppressedPlans.contains(plan.id) else { continue }
                guard let repository = configuration.repositories.first(where: { $0.id == plan.repositoryID }),
                    DestinationTriggerMapping.matches(volumeUUID: uuid, plan: plan, repository: repository)
                else { continue }
                var request =
                    pending[plan.id]
                    ?? MountRequest(
                        plan: plan, repository: repository, version: planVersions[plan.id, default: 0], evidence: [:])
                request.evidence[uuid] = deadline
                pending[plan.id] = request
            }
            await restartMountTimer()
        case .volumeUnmounted(let value):
            guard let uuid = DomainValidation.volumeUUID(value)?.uuidString else { return }
            presentVolumes.remove(uuid)
            for id in pending.keys {
                pending[id]?.evidence.removeValue(forKey: uuid)
                if pending[id]?.evidence.isEmpty == true { pending.removeValue(forKey: id) }
            }
            await restartMountTimer()
        case .network(let observation):
            guard lastNetwork != observation else { return }
            lastNetwork = observation
            await restartNetworkProbe(configuration, observation: observation)
        default: break
        }
    }

    private func deadline(_ request: MountRequest) -> C.Instant {
        max(loginReady, request.evidence.values.max() ?? loginReady)
    }

    private func restartMountTimer() async {
        mountVersion &+= 1
        let version = mountVersion
        let revision = revision
        let previous = mountTaskID.flatMap { tasks[$0] }
        mountTaskID = nil
        previous?.cancel()
        await previous?.value
        guard running, self.revision == revision, mountVersion == version,
            let deadline = pending.values.map(deadline).min()
        else { return }
        let id = UUID()
        let clock = clock
        mountTaskID = id
        tasks[id] = Task { [weak self] in
            await EventTriggerWorker.$id.withValue(id) {
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                    try Task.checkCancellation()
                    await self?.mountFired(revision: revision, version: version)
                } catch {}
                await self?.finished(id)
            }
        }
    }

    private func mountFired(revision: UInt64, version: UInt64) async {
        guard running, self.revision == revision, mountVersion == version else { return }
        mountTaskID = nil
        let ready = pending.values.filter { deadline($0) <= clock.now }.sorted {
            $0.plan.id.uuidString < $1.plan.id.uuidString
        }
        for request in ready { pending.removeValue(forKey: request.plan.id) }
        await restartMountTimer()
        for request in ready {
            guard running, self.revision == revision, !Task.isCancelled,
                !suppressedPlans.contains(request.plan.id),
                planVersions[request.plan.id, default: 0] == request.version,
                !presentVolumes.isDisjoint(with: request.evidence.keys)
            else { continue }
            await enqueue(request.plan, request.repository, trigger: .onVolumeMount)
        }
    }

    private func restartNetworkProbe(_ configuration: BackupConfiguration, observation: SystemNetworkObservation) async
    {
        networkVersion &+= 1
        let version = networkVersion
        let revision = revision
        let previousID = networkTaskID
        let previous = networkTaskID.flatMap { tasks[$0] }
        networkTaskID = nil
        previous?.cancel()
        if previousID != EventTriggerWorker.id { await previous?.value }
        guard running, self.revision == revision, networkVersion == version, observation.isAvailable else { return }
        let id = UUID()
        let clock = clock
        let loginReady = loginReady
        networkTaskID = id
        tasks[id] = Task { [weak self] in
            await EventTriggerWorker.$id.withValue(id) {
                do {
                    try await clock.sleep(until: loginReady, tolerance: nil)
                    try Task.checkCancellation()
                    await self?.probe(configuration, observation: observation, revision: revision, version: version)
                } catch {}
                await self?.finished(id)
            }
        }
    }

    private func probe(
        _ configuration: BackupConfiguration, observation: SystemNetworkObservation, revision: UInt64, version: UInt64
    ) async {
        // Serialize probes and share each result within this event, including failures. Never flood endpoints.
        var checked: [ReachabilityTarget: Bool] = [:]
        for plan in configuration.plans where plan.isEnabled && plan.triggers.contains(.onNetworkReachable) {
            guard currentNetwork(revision: revision, version: version) else { return }
            guard !suppressedPlans.contains(plan.id) else { continue }
            let planVersion = planVersions[plan.id, default: 0]
            if plan.conditions.skipOnExpensiveNetwork && observation.path.isExpensive != false { continue }
            if plan.conditions.skipOnConstrainedNetwork && observation.path.isConstrained != false { continue }
            guard plan.conditions.allowedWiFiSSIDs == nil,
                let repository = configuration.repositories.first(where: { $0.id == plan.repositoryID }),
                let target = DestinationTriggerMapping.networkTarget(
                    repository: repository, conditions: plan.conditions)
            else { continue }
            do {
                let reachable: Bool
                if let cached = checked[target] {
                    reachable = cached
                } else {
                    reachable = try await reachability.canConnect(to: target)
                    checked[target] = reachable
                }
                guard currentNetwork(revision: revision, version: version) else { return }
                guard !suppressedPlans.contains(plan.id), planVersions[plan.id, default: 0] == planVersion else {
                    continue
                }
                if reachable { await enqueue(plan, repository, trigger: .onNetworkReachable) }
            } catch {
                guard currentNetwork(revision: revision, version: version) else { return }
                guard !suppressedPlans.contains(plan.id), planVersions[plan.id, default: 0] == planVersion else {
                    continue
                }
                await failed(plan.id, error)
            }
        }
    }

    private func currentNetwork(revision: UInt64, version: UInt64) -> Bool {
        running && self.revision == revision && networkVersion == version && !Task.isCancelled
    }

    private func enqueue(_ plan: BackupPlan, _ repository: Repository, trigger: Trigger) async {
        do {
            try Task.checkCancellation()
            try await admit(plan, repository, ScheduledRequest(planID: plan.id, trigger: trigger, requestedAt: now()))
        } catch {
            if !Task.isCancelled { await failed(plan.id, error) }
        }
    }

    private func cancelAll() async {
        mountTaskID = nil
        networkTaskID = nil
        // A receiver may stop observation itself; it cannot await its own worker's completion.
        let active = tasks.filter { $0.key != EventTriggerWorker.id }.map(\.value)
        for task in active { task.cancel() }
        for task in active { await task.value }
    }

    private func finished(_ id: UUID) {
        tasks.removeValue(forKey: id)
        if mountTaskID == id { mountTaskID = nil }
        if networkTaskID == id { networkTaskID = nil }
    }
}

private enum EventTriggerWorker {
    @TaskLocal static var id: UUID?
}
