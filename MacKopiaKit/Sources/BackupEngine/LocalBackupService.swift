import BackupDomain
import Foundation
import KopiaCLI
import Persistence
import Secrets
import SystemIntegration

/// The agent owns exactly one service. All mutations and operation admission pass through it.
public actor LocalBackupService {
    let store: ConfigStore
    let history: HistoryStore
    let secrets: any SecretStore
    let executable: URL
    let home: URL
    let temporary: URL
    let version: String
    let clock: any Clock<Duration>
    let sourceAccess: any SourceAccessChecking
    let protection: any BackupOperationProtecting
    let gate: RepositoryOperationGate
    var configuration: BackupConfiguration?
    var active: UUID?
    var runtime: AutomaticBackupRuntime<ServiceClock>?
    let monitor: any SystemEventMonitoring
    let runtimeClock: ServiceClock
    let now: @Sendable () -> Date
    let loginDate: Date
    var mutating = false
    var stopped = false
    var started = false
    var lowSpacePlans: Set<UUID> = []
    var planIssues: [UUID: LocalServiceIssue] = [:]
    var issue: LocalServiceIssue?
    var progress: BackupProgress?
    var restoreState: RestoreState?
    var restoreTask: Task<Void, Never>?
    var previewDirectory: URL?
    var revision = UUID()
    var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(executable: URL, home: URL, temporary: URL, expectedVersion: String) throws {
        try self.init(
            executable: executable, home: home, temporary: temporary, expectedVersion: expectedVersion,
            secrets: AgentKeychainStore(),
            sourceAccess: LocalSourceAccessChecker(
                fullDiskAccess: AgentFullDiskAccessProbe(executable: executable, home: home, temporary: temporary)),
            protection: LocalBackupOperationProtection())
    }

    init(
        executable: URL, home: URL, temporary: URL, expectedVersion: String,
        secrets: any SecretStore, sourceAccess: any SourceAccessChecking, protection: any BackupOperationProtecting,
        clock: any Clock<Duration> = ContinuousClock(),
        monitor: any SystemEventMonitoring = LocalSystemEventMonitor(),
        runtimeClock: ServiceClock = ServiceClock(ContinuousClock()),
        now: @escaping @Sendable () -> Date = { .now }, loginDate: Date = .now
    ) throws {
        self.clock = clock
        self.monitor = monitor
        self.runtimeClock = runtimeClock; self.now = now; self.loginDate = loginDate
        self.sourceAccess = sourceAccess
        self.protection = protection
        self.executable = executable
        self.home = home
        self.temporary = temporary
        self.version = expectedVersion
        let directory = try LocalServiceStorage.prepare(home: home)
        store = try ConfigStore(directory: directory)
        history = try HistoryStore(directory: directory.appendingPathComponent("History"))
        self.secrets = secrets
        gate = try RepositoryOperationGate()
    }

    public func start() async throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard !started else { return }
        started = true
        switch try await store.load() {
        case .loaded(let config): configuration = config
        case .safeMode: issue = .safeMode
        }
        if configuration != nil {
            do { try await startRuntime() } catch { issue = .automationUnavailable }
        }
        changed()
    }

    public func state(after previous: UUID? = nil) async throws -> LocalServiceState {
        if previous == revision, !stopped {
            guard observers.count < 8 else { throw LocalServiceIssue.busy }
            let id = UUID()
            let stream = AsyncStream<Void> { observers[id] = $0 }
            let clock = clock
            let timeout = Task { [weak self] in
                do { try await clock.sleep(for: .seconds(25)); await self?.removeObserver(id) } catch {}
            }
            await withTaskCancellationHandler {
                for await _ in stream { break }
            } onCancel: {
                Task { await self.removeObserver(id) }
            }
            timeout.cancel()
            removeObserver(id)
        }
        try Task.checkCancellation()
        let queued = await runtime?.currentPlanID()
        let snapshot = (configuration, active ?? queued, progress, issue, revision)
        let runs = try await history.recent(limit: 50)
        let plans = try await runtimeProjection()
        let pause = await runtime?.pauseState()
        return LocalServiceState(
            configuration: snapshot.0, runs: runs,
            activePlanID: snapshot.1, progress: snapshot.2, issue: snapshot.3, revision: snapshot.4, plans: plans,
            globalPause: pause, restore: restoreState)
    }

    func performSetup(
        name: String, destination: BackupSource, source: BackupSource, password: String, create: Bool
    ) async throws {
        guard password.utf8.count <= 65_536, !password.isEmpty, !password.utf8.contains(0),
            !create || password.count >= 12, let config = configuration
        else { throw LocalServiceIssue.invalidRequest }
        let sourceURL = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
        let destinationURL = URL(fileURLWithPath: destination.path).resolvingSymlinksInPath()
        try source.volume.requireMatch(uuid: volume(sourceURL).uuid)
        try destination.volume.requireMatch(uuid: volume(destinationURL).uuid)
        guard sourceURL.path == source.path, destinationURL.path == destination.path else {
            throw LocalServiceIssue.destination
        }
        guard
            !config.repositories.contains(where: {
                if case .filesystem(let path, _) = $0.kind { return path == destinationURL.path }
                return false
            })
        else { throw LocalServiceIssue.destination }
        let repository = try Repository(
            name: name, kind: .filesystem(path: destinationURL.path, volume: destination.volume),
            identity: config.repositories.first?.identity
                ?? SnapshotIdentity(overrideUser: NSUserName(), overrideHost: ProcessInfo.processInfo.hostName),
            secretRef: SecretRef())
        let plan = try LocalPlanFactory.make(name: name, source: source, repositoryID: repository.id)
        // Reject recursion/overlap before touching the destination or storing a credential.
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(
            repositories: config.repositories + [repository], plans: config.plans + [plan],
            notificationsEnabled: config.notificationsEnabled)
        do { try await secrets.write(SecretValue(data: Data(password.utf8)), for: repository.secretRef) } catch {
            throw LocalServiceIssue.keychain
        }
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        try await KopiaBinaryVerifier(
            executable: executable, paths: paths, temporaryDirectory: temporary,
            expectedVersion: version
        ).verify()
        do {
            try await gate.withOperation(repositoryID: repository.id) {
                try await self.protection.withProtection(sources: plan.sources, repository: repository) {
                    _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
                    guard case .filesystem(let path, let volume) = repository.kind, let volume,
                        try await FilesystemDestinationPreflight().validate(path: path, expectedVolume: volume)
                            != .insufficientSpace
                    else { throw LocalServiceIssue.destination }
                    try await KopiaLocalSetup(
                        executable: self.executable, home: self.home, temporary: self.temporary,
                        user: NSUserName()
                    ).perform(repository: repository, password: password, create: create)
                }
            }
            try Task.checkCancellation()
            try await persist(updated)
        } catch {
            // Never remove destination data or a possibly committed secret after an uncertain write.
            if error as? LocalServiceIssue == .safeMode { throw LocalServiceIssue.safeMode }
            issue = .destination
            throw LocalServiceIssue.destination
        }
    }

    func performCreatePlan(name: String, repositoryID: UUID, source: BackupSource) async throws {
        guard let config = configuration, let repository = config.repositories.first(where: { $0.id == repositoryID })
        else {
            throw LocalServiceIssue.invalidRequest
        }
        let url = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
        try source.volume.requireMatch(uuid: volume(url).uuid)
        guard url.path == source.path else { throw LocalServiceIssue.destination }
        let plan = try LocalPlanFactory.make(name: name, source: source, repositoryID: repositoryID)
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(
            repositories: config.repositories, plans: config.plans + [plan],
            notificationsEnabled: config.notificationsEnabled)
        try await persist(updated)
    }

    func performRecoverConfiguration() async throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard configuration == nil else { throw LocalServiceIssue.invalidRequest }
        do {
            configuration = try await store.restoreBackup()
            issue = nil
        } catch { throw LocalServiceIssue.safeMode }
    }

    func performSavePlan(_ plan: BackupPlan) async throws {
        guard let config = configuration, config.plans.contains(where: { $0.id == plan.id }),
            plan.options.parallelism == nil, plan.options.uploadLimitMbps == nil
        else { throw LocalServiceIssue.invalidRequest }
        guard let repository = config.repositories.first(where: { $0.id == plan.repositoryID }) else {
            throw LocalServiceIssue.invalidRequest
        }
        if plan.options.ejectVolumeAfterBackup {
            guard case .filesystem(_, let volume) = repository.kind, volume?.isRemovable == true,
                volume?.isNetwork == false
            else { throw LocalServiceIssue.invalidRequest }
        }
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(
            repositories: config.repositories, plans: config.plans.map { $0.id == plan.id ? plan : $0 },
            notificationsEnabled: config.notificationsEnabled)
        try await persist(updated)
    }

    public func run(_ planID: UUID) async throws {
        try availableForMutation()
        guard let config = configuration, config.plans.contains(where: { $0.id == planID && $0.isEnabled }),
            let runtime
        else { throw LocalServiceIssue.invalidRequest }
        do { try await runtime.enqueue(planID: planID) } catch JobAdmissionError.planPaused {
            throw LocalServiceIssue.planPaused
        } catch { throw LocalServiceIssue.backupFailed }
        changed()
    }

    public func stop(_ planID: UUID) async throws {
        guard !stopped, let runtime, configuration?.plans.contains(where: { $0.id == planID }) == true else {
            throw LocalServiceIssue.invalidRequest
        }
        try await runtime.stop(planID: planID)
        changed()
    }

    public func shutdown() async {
        stopped = true
        restoreTask?.cancel()
        await restoreTask?.value
        try? clearRestorePreview()
        await runtime?.shutdown()
        while mutating {
            let id = UUID()
            let stream = AsyncStream<Void> { observers[id] = $0 }
            for await _ in stream { break }
            removeObserver(id)
        }
        changed()
    }

    func persist(_ updated: BackupConfiguration) async throws {
        do {
            try await store.save(updated)
            configuration = updated
            issue = nil
        } catch {
            configuration = nil
            issue = .safeMode
            throw LocalServiceIssue.safeMode
        }
    }

    func availableForMutation() throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard configuration != nil else { throw LocalServiceIssue.safeMode }
        guard !mutating, restoreTask == nil else { throw LocalServiceIssue.busy }
    }
    func received(_ value: BackupProgress) { progress = value; changed() }
    func activity(_ id: UUID?) {
        active = id; progress = nil
        if let id {
            planIssues.removeValue(forKey: id)
            if issue != .safeMode && issue != .automationUnavailable { issue = planIssues.values.first }
        }
        changed()
    }
    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
    func changed() {
        revision = UUID()
        let pending = observers.values
        observers.removeAll()
        for observer in pending { observer.yield(); observer.finish() }
    }
    func volume(_ url: URL) throws -> VolumeIdentity {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .volumeUUIDStringKey, .volumeNameKey, .volumeIsRemovableKey, .volumeIsLocalKey,
        ])
        guard values.isDirectory == true, values.volumeIsLocal == true, let uuid = values.volumeUUIDString else {
            throw LocalServiceIssue.destination
        }
        return try VolumeIdentity(
            uuid: uuid, name: values.volumeName ?? "Volume", isRemovable: values.volumeIsRemovable ?? false,
            isNetwork: false)
    }
}
