import BackupDomain
import Foundation
import KopiaCLI
import Persistence
import Secrets
import SystemIntegration

/// The agent owns exactly one service. All mutations and operation admission pass through it.
public actor LocalBackupService {
    private let store: ConfigStore
    private let history: HistoryStore
    private let secrets: any SecretStore
    private let executable: URL
    private let home: URL
    private let temporary: URL
    private let version: String
    private let clock: any Clock<Duration>
    private let sourceAccess: any SourceAccessChecking
    private let protection: any BackupOperationProtecting
    private let gate: RepositoryOperationGate
    private var configuration: BackupConfiguration?
    private var active: (UUID, Task<Void, Never>)?
    private var mutating = false
    private var stopped = false
    private var started = false
    private var issue: LocalServiceIssue?
    private var progress: BackupProgress?
    private var revision = UUID()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]

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
        clock: any Clock<Duration> = ContinuousClock()
    ) throws {
        self.clock = clock
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
        _ = try await history.reconcileInterrupted(at: .now, workIDs: [])
        switch try await store.load() {
        case .loaded(let config): configuration = config
        case .safeMode: issue = .safeMode
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
        let snapshot = (configuration, active?.0, progress, issue, revision)
        let runs = try await history.recent(limit: 50)
        return LocalServiceState(
            configuration: snapshot.0, runs: runs,
            activePlanID: snapshot.1, progress: snapshot.2, issue: snapshot.3, revision: snapshot.4)
    }

    public func setup(
        name: String, destination: BackupSource, source: BackupSource, password: String, create: Bool
    ) async throws {
        try availableForMutation()
        mutating = true
        defer { mutating = false; changed() }
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
            repositories: config.repositories + [repository], plans: config.plans + [plan])
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

    public func createPlan(name: String, repositoryID: UUID, source: BackupSource) async throws {
        try availableForMutation()
        guard let config = configuration, let repository = config.repositories.first(where: { $0.id == repositoryID })
        else {
            throw LocalServiceIssue.invalidRequest
        }
        mutating = true
        defer { mutating = false; changed() }
        let url = URL(fileURLWithPath: source.path).resolvingSymlinksInPath()
        try source.volume.requireMatch(uuid: volume(url).uuid)
        guard url.path == source.path else { throw LocalServiceIssue.destination }
        let plan = try LocalPlanFactory.make(name: name, source: source, repositoryID: repositoryID)
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(repositories: config.repositories, plans: config.plans + [plan])
        try await persist(updated)
    }

    public func recoverConfiguration() async throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard !mutating, active == nil else { throw LocalServiceIssue.busy }
        guard configuration == nil else { throw LocalServiceIssue.invalidRequest }
        mutating = true
        defer { mutating = false; changed() }
        do {
            configuration = try await store.restoreBackup()
            issue = nil
        } catch { throw LocalServiceIssue.safeMode }
    }

    public func savePlan(_ plan: BackupPlan) async throws {
        try availableForMutation()
        guard let config = configuration, config.plans.contains(where: { $0.id == plan.id }),
            plan.triggers == [.manual], plan.options.parallelism == nil, plan.options.uploadLimitMbps == nil,
            !plan.options.ejectVolumeAfterBackup
        else { throw LocalServiceIssue.invalidRequest }
        mutating = true
        defer { mutating = false; changed() }
        guard let repository = config.repositories.first(where: { $0.id == plan.repositoryID }) else {
            throw LocalServiceIssue.invalidRequest
        }
        _ = try await BackupPathPreflight().validate(plan: plan, repository: repository)
        let updated = try BackupConfiguration(
            repositories: config.repositories, plans: config.plans.map { $0.id == plan.id ? plan : $0 })
        try await persist(updated)
    }

    public func run(_ planID: UUID) async throws {
        try availableForMutation()
        guard let config = configuration, let plan = config.plans.first(where: { $0.id == planID }), plan.isEnabled,
            let repository = config.repositories.first(where: { $0.id == plan.repositoryID })
        else { throw LocalServiceIssue.invalidRequest }
        mutating = true
        defer { mutating = false; changed() }
        let paths = try KopiaRepositoryPaths(repositoryID: repository.id, homeDirectory: home)
        let binary = try KopiaBinaryVerifier(
            executable: executable, paths: paths, temporaryDirectory: temporary, expectedVersion: version)
        // Both agent and bundled child must establish fresh protected-file access on every preflight.
        let preflight = BackupPreflight(
            prerequisites: BackupPrerequisitePreflight(binary: binary, secrets: secrets), gate: gate,
            sourceAccess: sourceAccess)
        let report = try await preflight.evaluate(plan: plan, repository: repository)
        guard report.outcome == .checksPassed else {
            if report.checks.contains(where: { $0.action == .checkSourceAccess }) {
                issue = .permissions
            } else if report.checks.contains(where: { $0.action == .checkKeychain || $0.action == .enterBackupPassword }
            ) {
                issue = .keychain
            } else {
                issue = .destination
            }
            changed()
            throw issue ?? .backupFailed
        }
        let engine = ManualBackupEngine(
            runner: ConfiguredJobRunner(
                store: store, queue: JobQueue(),
                coordinator: BackupOperationCoordinator(preflight: preflight, protection: protection)),
            sessions: FilesystemBackupSessions(
                executable: executable, homeDirectory: home, temporaryDirectory: temporary,
                user: NSUserName(), secrets: secrets), history: history, resolver: try TimeMachineExclusionResolver(),
            homeDirectory: home.path, progress: { [weak self] value in await self?.received(value) })
        try await engine.enqueue(planID: planID)
        issue = nil
        let task = Task { [weak self] in
            do {
                let result = try await engine.performNext()
                await self?.finished(failed: result?.outcome == .failed || result?.outcome == .skipped)
            } catch { await self?.finished(failed: !(error is CancellationError)) }
        }
        active = (planID, task)
        changed()
    }

    public func stop(_ planID: UUID) throws {
        guard active?.0 == planID else { throw LocalServiceIssue.invalidRequest }
        active?.1.cancel()
    }

    public func shutdown() async {
        stopped = true
        active?.1.cancel()
        await active?.1.value
        while mutating {
            let id = UUID()
            let stream = AsyncStream<Void> { observers[id] = $0 }
            for await _ in stream { break }
            removeObserver(id)
        }
        changed()
    }

    private func persist(_ updated: BackupConfiguration) async throws {
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

    private func availableForMutation() throws {
        guard !stopped else { throw LocalServiceIssue.unavailable }
        guard configuration != nil else { throw LocalServiceIssue.safeMode }
        guard !mutating, active == nil else { throw LocalServiceIssue.busy }
    }
    private func received(_ value: BackupProgress) { progress = value; changed() }
    private func finished(failed: Bool) {
        active = nil; progress = nil; issue = failed ? .backupFailed : nil; changed()
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id)?.finish() }
    private func changed() {
        revision = UUID()
        let pending = observers.values
        observers.removeAll()
        for observer in pending { observer.yield(); observer.finish() }
    }
    private func volume(_ url: URL) throws -> VolumeIdentity {
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
