import BackupDomain
import Foundation
import KopiaServer
import Persistence
import Synchronization
import SystemIntegration
import Testing

@testable import BackupEngine
@testable import Persistence

struct ManualBackupEngineTests {
    @Test func twoSourcesExecuteSequentiallyAndHistoryFinishesAfterCleanup() async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService()
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(fixture, service: service, history: history)
        let job = try await engine.enqueue(planID: fixture.plan.id)
        let result = try #require(try await engine.performNext())
        #expect(result.id == job.id)
        #expect(result.outcome == .succeeded)
        #expect(result.sources.map(\.sourceID) == fixture.plan.sources.map(\.id))
        #expect(result.sources.map(\.bytes) == [42, 42])
        #expect(await service.uploaded == fixture.plan.sources.map(\.path))
        #expect(await history.final == result)
        #expect(try await engine.performNext() == nil)
    }

    @Test(arguments: [
        ManualBackupService.Mode.uploadFailure, .incomplete, .cleanupFailure, .wrongIdentity, .duplicateManifest,
    ])
    func failureIsRecordedAndCleanupFinishesBeforeQueueRelease(mode: ManualBackupService.Mode) async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService(mode: mode)
        let history = ManualHistoryFixture(service: service)
        let queue = JobQueue()
        let engine = try await engine(fixture, service: service, history: history, queue: queue)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let expected: BackupOperationError
        switch mode {
        case .incomplete: expected = .snapshotIncomplete
        case .duplicateManifest: expected = .snapshotReferenceMissing
        default: expected = .operationFailed
        }
        await #expect(throws: expected) { try await engine.performNext() }
        #expect(await history.final?.outcome == .failed)
        #expect(await service.closed)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        #expect(await queue.takeNext() != nil)
        if mode == .cleanupFailure { #expect(await history.final?.issues.contains(.cleanup) == true) }
    }

    @Test func cancellationStopsCurrentSourceSkipsRemainingAndRecordsHistory() async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService(mode: .waitForCancellation)
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(fixture, service: service, history: history)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let task = Task { try await engine.performNext() }
        await service.waitUntilUpload()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await service.uploaded.count == 1)
        #expect(await service.cancellations == 1)
        #expect(await history.final?.outcome == .cancelled)
        #expect(await service.closed)
    }

    @Test(arguments: [0, 1, 2])
    func queuePauseOrStopUsesSourceCancellationAndFinishesHistoryBeforeReturning(action: Int) async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService(mode: .waitForCancellation)
        let history = ManualHistoryFixture(service: service)
        let queue = JobQueue()
        let engine = try await engine(fixture, service: service, history: history, queue: queue)
        let original = try await engine.enqueue(planID: fixture.plan.id)
        let running = Task { try await engine.performNext() }
        await service.waitUntilUpload()
        switch action {
        case 0: await queue.pause(planID: fixture.plan.id)
        case 1: await queue.pause()
        default: await queue.stop(planID: fixture.plan.id)
        }
        #expect(await service.cancellations == 1)
        #expect(await service.uploaded.count == 1)
        #expect(await service.closed)
        #expect(await history.final?.outcome == .cancelled)
        #expect(await queue.complete(original) == false)
        await #expect(throws: CancellationError.self) { try await running.value }
        if action == 2 {
            #expect(await queue.takeNext() == nil)
            #expect(await queue.isPaused(fixture.plan.id) == false)
            _ = try await engine.enqueue(planID: fixture.plan.id)
        } else {
            await #expect(throws: JobAdmissionError.planPaused) { try await engine.enqueue(planID: fixture.plan.id) }
            try await queue.resume(planID: action == 0 ? fixture.plan.id : nil, requestedAt: .now)
        }
        let next = try #require(await queue.takeNext())
        #expect(next.id != original.id)
        #expect(next.plan.id == original.plan.id)
        #expect(await queue.complete(next))
        #expect(await queue.takeNext() == nil)
    }

    @Test func blockedPreflightRecordsSkipWithoutOpeningServer() async throws {
        let fixture = try PreflightTestFixture(scenario: PreflightTestScenario(sourceAccess: .unknown))
        let service = ManualBackupService()
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(fixture, service: service, history: history)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        #expect(try await engine.performNext()?.outcome == .skipped)
        #expect(await service.uploaded.isEmpty)
        #expect(await service.opened == false)
    }

    @Test(arguments: [false, true])
    func historyWriteFailuresReleaseQueueAndNeverReportSuccess(finishFails: Bool) async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService()
        let history = ManualHistoryFixture(service: service, failBegin: !finishFails, failFinish: finishFails)
        let queue = JobQueue()
        let engine = try await engine(fixture, service: service, history: history, queue: queue)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await engine.performNext() }
        #expect(await service.opened == finishFails)
        if finishFails { #expect(await service.closed) }
        _ = try await engine.enqueue(planID: fixture.plan.id)
        #expect(await queue.takeNext() != nil)
    }

    @Test(arguments: [false, true])
    func missingSourcesAndFileErrorsProduceWarnings(fileErrors: Bool) async throws {
        let fixture = try PreflightTestFixture(
            scenario: PreflightTestScenario(missingSources: fileErrors ? [] : ["/Other"]))
        let service = ManualBackupService(mode: fileErrors ? .fileWarnings : .normal)
        let engine = try await engine(fixture, service: service, history: ManualHistoryFixture(service: service))
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let run = try #require(try await engine.performNext())
        #expect(run.outcome == .succeededWithWarnings)
        #expect(run.issues.contains(fileErrors ? .fileErrors : .missingSource))
        #expect(run.sources.count == (fileErrors ? 2 : 1))
        if fileErrors {
            #expect(run.sources.allSatisfy { $0.errors == 2 && $0.ignoredErrors == 1 })
        }
    }

    @Test func cancellationFailureStillClosesSessionAndLeavesExplicitHistoryIssue() async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService(mode: .cancelFailure)
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(fixture, service: service, history: history)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let task = Task { try await engine.performNext() }
        await service.waitUntilUpload()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await service.closed)
        #expect(await history.final?.issues.contains(.cancellationUnconfirmed) == true)
    }

    @Test(arguments: [0, 1, 2])
    func unsupportedRunOptionsBlockBeforeOpeningServer(option: Int) async throws {
        let fixture = try PreflightTestFixture()
        let original = fixture.plan
        let plan = try BackupPlan(
            id: original.id, name: original.name, isEnabled: true,
            repositoryID: original.repositoryID, sources: original.sources, triggers: original.triggers,
            conditions: original.conditions, retention: original.retention, excludes: original.excludes,
            options: PlanOptions(
                parallelism: option == 0 ? 2 : nil, lowPriority: true,
                uploadLimitMbps: option == 1 ? 1 : nil, ejectVolumeAfterBackup: option == 2), health: original.health)
        let service = ManualBackupService()
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(fixture, service: service, history: history, plan: plan)
        _ = try await engine.enqueue(planID: plan.id)
        await #expect(throws: BackupOperationError.unsupportedOptions) { try await engine.performNext() }
        #expect(await service.opened == false)
        #expect(await history.final?.outcome == .failed)
    }

    @Test(arguments: [ManualBackupService.Mode.normal, .uploadFailure, .cleanupFailure, .waitForCancellation])
    func sleepProtectionSurvivesExecutionAndReleasesOnEveryExit(mode: ManualBackupService.Mode) async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService(mode: mode)
        let sleep = TestSleepPreventer()
        let engine = try await engine(
            fixture, service: service, history: ManualHistoryFixture(service: service), sleep: sleep)
        _ = try await engine.enqueue(planID: fixture.plan.id)
        let task = Task { try await engine.performNext() }
        await service.waitUntilUpload()
        if mode == .waitForCancellation {
            #expect(sleep.active)
            task.cancel()
        }
        let result = await task.result
        if mode == .normal {
            #expect(try result.get()?.outcome == .succeeded)
        } else {
            if case .success = result { Issue.record("Expected execution failure") }
        }
        #expect(await service.closed)
        #expect(!sleep.active)
        #expect(sleep.acquisitions == 1)
    }

    @Test func failedSleepProtectionBlocksServerAndFinishesFailedHistory() async throws {
        let fixture = try PreflightTestFixture()
        let service = ManualBackupService()
        let history = ManualHistoryFixture(service: service)
        let engine = try await engine(
            fixture, service: service, history: history, sleep: TestSleepPreventer(fails: true))
        _ = try await engine.enqueue(planID: fixture.plan.id)
        await #expect(throws: BackupOperationError.operationFailed) { try await engine.performNext() }
        #expect(await service.opened == false)
        #expect(await history.final?.outcome == .failed)
    }

    private func engine(
        _ fixture: PreflightTestFixture, service: ManualBackupService, history: ManualHistoryFixture,
        queue: JobQueue = JobQueue(), plan: BackupPlan? = nil, sleep: any SleepPreventing = TestSleepPreventer()
    ) async throws -> ManualBackupEngine {
        if let sleep = sleep as? TestSleepPreventer {
            await service.setClosingCheck { #expect(sleep.active) }
        }
        let store = ConfigStore(files: MemoryConfigFiles(), codec: try ConfigCodec())
        _ = try await store.load()
        try await store.save(BackupConfiguration(repositories: [fixture.repository], plans: [plan ?? fixture.plan]))
        return ManualBackupEngine(
            runner: ConfiguredJobRunner(
                store: store, queue: queue,
                coordinator: BackupOperationCoordinator(
                    preflight: fixture.preflight, protection: ManualTestProtection())),
            sessions: ManualSessionFactory(service: service), history: history,
            resolver: try TimeMachineExclusionResolver(), homeDirectory: "/Home", sleep: sleep)
    }
}

struct ManualTestProtection: BackupOperationProtecting {
    func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository, operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result { try await operation() }
}

private struct ManualSessionFactory: BackupSessionOpening {
    let service: ManualBackupService
    func open(repository: Repository, options: PlanOptions) async throws -> KopiaBackupSession {
        await service.markOpened()
        return KopiaBackupSession(service: service) { try await service.close() }
    }
}

private actor ManualHistoryFixture: JobHistoryRecording {
    let service: ManualBackupService
    var final: JobRun?
    let failBegin: Bool
    let failFinish: Bool
    init(service: ManualBackupService, failBegin: Bool = false, failFinish: Bool = false) {
        self.service = service
        self.failBegin = failBegin
        self.failFinish = failFinish
    }
    func begin(_ run: JobRun) throws {
        #expect(run.outcome == .running)
        if failBegin { throw ConfigStoreError.storageUnavailable }
    }
    func finish(_ run: JobRun) async throws {
        if await service.opened { #expect(await service.closed) }
        if failFinish { throw ConfigStoreError.storageUnavailable }
        final = run
    }
}

actor ManualBackupService: KopiaBackupServing {
    enum Mode: Sendable {
        case normal, uploadFailure, incomplete, cleanupFailure, waitForCancellation, wrongIdentity, fileWarnings,
            cancelFailure, duplicateManifest
    }
    let mode: Mode
    var documents: [String: KopiaPolicyDocument] = [:]
    var uploaded: [String] = []
    var cancellations = 0
    var closed = false
    var opened = false
    private var closingCheck: (@Sendable () -> Void)?
    func setClosingCheck(_ check: @escaping @Sendable () -> Void) { closingCheck = check }
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(mode: Mode = .normal) { self.mode = mode }
    func markOpened() { opened = true }
    func pinSnapshot(id: String) throws -> KopiaSnapshot { throw BackupOperationError.operationFailed }
    func close() throws {
        closingCheck?()
        closed = true
        if mode == .cleanupFailure { throw BackupOperationError.operationFailed }
    }
    func waitUntilUpload() async {
        if !uploaded.isEmpty { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func repositoryStatus() throws -> KopiaRepositoryStatus {
        try decode(#"{"connected":true,"storage":"filesystem"}"#)
    }
    func sources() throws -> KopiaSources {
        let entries: [[String: Any]] = uploaded.map { path in
            [
                "source": ["path": path, "userName": "test", "host": "test-host"],
                "status": (mode == .waitForCancellation || mode == .cancelFailure) && cancellations == 0
                    ? "UPLOADING" : "IDLE",
                "upload": ["hashedBytes": 2, "cachedBytes": 1, "uploadedBytes": 0, "estimatedBytes": 42],
                "lastSnapshot": [
                    "id": "snapshot-" + path, "endTime": "end",
                    "stats": [
                        "errorCount": mode == .fileWarnings ? 2 : 0, "ignoredErrorCount": mode == .fileWarnings ? 1 : 0,
                    ],
                    "incomplete": mode == .incomplete ? "canceled" : "",
                ],
            ]
        }
        return try JSONDecoder().decode(
            KopiaSources.self,
            from: JSONSerialization.data(withJSONObject: [
                "localUsername": mode == .wrongIdentity ? "other" : "test", "localHost": "test-host",
                "sources": entries,
            ]))
    }
    func snapshotManifests(source: KopiaSnapshotSource) throws -> KopiaSnapshots {
        var entries: [[String: Any]] =
            uploaded.contains(source.path)
            ? [
                [
                    "id": "snapshot-" + source.path, "rootID": "root",
                    "summary": ["size": 42, "files": 3, "numFailed": 0],
                ]
            ] : []
        if mode == .duplicateManifest { entries += entries }
        return try JSONDecoder().decode(
            KopiaSnapshots.self, from: JSONSerialization.data(withJSONObject: ["snapshots": entries]))
    }
    func startUpload(source: KopiaSnapshotSource) throws {
        uploaded.append(source.path)
        for waiter in waiting { waiter.resume() }; waiting.removeAll()
        if mode == .uploadFailure { throw BackupOperationError.operationFailed }
    }
    func cancelUpload(source: KopiaSnapshotSource) throws {
        cancellations += 1
        if mode == .cancelFailure { throw BackupOperationError.operationFailed }
    }
    func policyDefinition(source: KopiaSnapshotSource) -> KopiaSourcePolicyDefinition? {
        documents[source.path].map { KopiaSourcePolicyDefinition(source: source, document: $0) }
    }
    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) -> KopiaPolicyDocument {
        updates ?? documents[source.path] ?? KopiaPolicyDocument()
    }
    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) { documents[source.path] = document }
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

private final class TestSleepPreventer: SleepPreventing, SleepAssertionHolding {
    private let state = Mutex((active: false, acquisitions: 0))
    let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    var active: Bool { state.withLock { $0.active } }
    var acquisitions: Int { state.withLock { $0.acquisitions } }
    func acquire() throws -> any SleepAssertionHolding {
        if fails { throw SleepAssertionError.unavailable }
        state.withLock {
            $0.active = true; $0.acquisitions += 1
        }
        return self
    }
    func release() { state.withLock { $0.active = false } }
}
