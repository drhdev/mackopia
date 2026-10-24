import BackupDomain
import Foundation
import KopiaServer
import Synchronization
import SystemIntegration
import Testing

@testable import BackupEngine

struct SourcePolicySynchronizerTests {
    func source(path: String = "/Synthetic Source") throws -> BackupSource {
        try BackupSource(
            path: path,
            volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false))
    }

    func plan(
        source: BackupSource, patterns: [String] = [], defaults: Bool = false, timeMachine: Bool = false
    ) throws -> BackupPlan {
        try BackupPlan(
            name: "Test", isEnabled: true, repositoryID: UUID(), sources: [source], triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(keepLatest: 0, keepDaily: 7),
            excludes: ExcludeRules(
                useMacOSDefaults: defaults, honorTimeMachineExclusions: timeMachine,
                ignoreCacheDirs: false, patterns: patterns, oneFileSystem: true),
            options: PlanOptions(compression: .none, lowPriority: true, ejectVolumeAfterBackup: false),
            health: HealthThresholds())
    }

    func run(_ sync: SourcePolicySynchronizer, plan: BackupPlan, source: BackupSource) async throws -> Bool {
        try await sync.synchronize(
            plan: plan, source: source,
            identity: SnapshotIdentity(overrideUser: "user+tag", overrideHost: "host+tag"),
            homeDirectory: "/Synthetic Source")
    }

    @Test func writesOncePreservesForeignFieldsAndRevalidatesOnSecondRun() async throws {
        let source = try source()
        let plan = try plan(source: source, patterns: ["*.tmp", "!keep.tmp", "*.tmp"])
        let existing = try KopiaPolicyDocument(
            data: Data(
                #"{"future":{"large":184467440737095516160},"files":{"ignoreDotFiles":[".custom"]},"retention":{"ignoreIdenticalSnapshots":true},"scheduling":{"manual":true}}"#
                    .utf8))
        let service = PolicyServiceFixture(stored: existing)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        #expect(try await run(sync, plan: plan, source: source))
        #expect(try await !run(sync, plan: plan, source: source))
        #expect(await service.writes == 1)
        #expect(await service.previews == 6)
        let stored = try #require(await service.stored)
        #expect(stored.value(for: "future") == existing.value(for: "future"))
        #expect(stored.value(for: "scheduling") == existing.value(for: "scheduling"))
        #expect(!String(reflecting: stored).contains(".custom"))
    }

    @Test(arguments: [PolicyServiceFixture.Mode.localConflict, .parentConflict, .foreignSelector])
    func rejectsObservedConflictsBeforeWriting(mode: PolicyServiceFixture.Mode) async throws {
        let source = try source()
        let service = PolicyServiceFixture(mode: mode)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        await #expect(throws: PolicySynchronizationError.conflict) {
            try await run(sync, plan: plan(source: source), source: source)
        }
        #expect(await service.writes == 0)
    }

    @Test(arguments: [PolicyServiceFixture.Mode.inheritedIgnore, .inheritedSize, .inheritedSchedule])
    func inheritedRulesThatDefeatThePlanBlockWrites(mode: PolicyServiceFixture.Mode) async throws {
        let source = try source()
        let service = PolicyServiceFixture(mode: mode)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        let expected: PolicySynchronizationError = mode == .inheritedSchedule ? .schedulingEnabled : .effectiveMismatch
        await #expect(throws: expected) { try await run(sync, plan: plan(source: source), source: source) }
        #expect(await service.writes == 0)
    }

    @Test func existingSchedulingIsPreservedAndBlocksInsteadOfBeingDisabled() async throws {
        let source = try source()
        let existing = try KopiaPolicyDocument(data: Data(#"{"scheduling":{"intervalSeconds":3600}}"#.utf8))
        let service = PolicyServiceFixture(stored: existing)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        await #expect(throws: PolicySynchronizationError.schedulingEnabled) {
            try await run(sync, plan: plan(source: source), source: source)
        }
        #expect(await service.writes == 0)
        #expect(await service.stored == existing)
    }

    @Test(arguments: [PolicyServiceFixture.Mode.postWriteConflict, .uncertainWrite])
    func neverRollsBackOrRetriesUncertainWrites(mode: PolicyServiceFixture.Mode) async throws {
        let source = try source()
        let service = PolicyServiceFixture(mode: mode)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        await #expect(throws: (any Error).self) { try await run(sync, plan: plan(source: source), source: source) }
        #expect(await service.writes == 1)
        #expect(await service.stored != nil)
    }

    @Test func preCancelledAndForeignSourceNeverAccessServer() async throws {
        let source = try source()
        let plan = try plan(source: source)
        let service = PolicyServiceFixture()
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await run(sync, plan: plan, source: source)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await #expect(throws: DomainValidationError.invalidPlan) {
            try await run(sync, plan: plan, source: self.source())
        }
        #expect(await service.reads == 0)
    }

    @Test func combinesMacOSAndFreshTimeMachineRulesBeforeUserNegations() async throws {
        let source = try source()
        let service = PolicyServiceFixture()
        let resolver = try TimeMachineExclusionResolver(inspector: ExcludedRoot(volume: source.volume.uuid))
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: resolver)
        let plan = try plan(source: source, patterns: ["!keep"], defaults: true, timeMachine: true)
        #expect(try await run(sync, plan: plan, source: source))
        let stored = try #require(await service.stored)
        let files = try #require(stored.value(for: "files"))
        struct Files: Decodable { let ignore: [String] }
        let patterns = try JSONDecoder().decode(Files.self, from: files).ignore
        #expect(
            patterns == (try MacOSExclusionPatterns.resolve(for: source, homeDirectory: source.path)) + ["**", "!keep"])
    }

    @Test func concurrentEntryIsRejectedAndCancellationReleasesAdmission() async throws {
        let source = try source()
        let plan = try plan(source: source)
        let service = PolicyServiceFixture(mode: .blockedPreview)
        let sync = SourcePolicySynchronizer(service: service, timeMachineResolver: try TimeMachineExclusionResolver())
        let first = Task { try await run(sync, plan: plan, source: source) }
        await service.waitUntilBlocked()
        await #expect(throws: PolicySynchronizationError.busy) { try await run(sync, plan: plan, source: source) }
        first.cancel()
        await service.releasePreview()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await service.writes == 0)
        #expect(try await run(sync, plan: plan, source: source))
    }

    @Test func exclusionSnapshotExpiringDuringPreviewBlocksWrite() async throws {
        let source = try source()
        let plan = try plan(source: source, timeMachine: true)
        let service = PolicyServiceFixture(mode: .blockedPreview)
        let clock = Mutex(ContinuousClock.now)
        let resolver = try TimeMachineExclusionResolver(
            inspector: ExcludedRoot(volume: source.volume.uuid), now: { clock.withLock { $0 } })
        let sync = SourcePolicySynchronizer(
            service: service, timeMachineResolver: resolver, now: { clock.withLock { $0 } })
        let first = Task { try await run(sync, plan: plan, source: source) }
        await service.waitUntilBlocked()
        clock.withLock { $0 = $0.advanced(by: .seconds(61)) }
        await service.releasePreview()
        await #expect(throws: TimeMachineExclusionError.staleResult) { try await first.value }
        #expect(await service.writes == 0)
    }

    private struct ExcludedRoot: TimeMachineExclusionInspecting {
        let volume: String
        func inspect(_ path: String) async throws -> TimeMachineExclusionEntry {
            TimeMachineExclusionEntry(volumeUUID: volume, isDirectory: true, isSymbolicLink: false, isExcluded: true)
        }
        func children(of path: String, limit: Int) async throws -> [String] { [] }
    }
}

actor PolicyServiceFixture: KopiaPolicyServing {
    enum Mode: Sendable {
        case normal, localConflict, parentConflict, foreignSelector, inheritedIgnore, inheritedSize, inheritedSchedule,
            postWriteConflict, uncertainWrite, blockedPreview
    }
    let mode: Mode
    var stored: KopiaPolicyDocument?
    var reads = 0
    var previews = 0
    var writes = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func releasePreview() { blocked?.resume(); blocked = nil }

    init(mode: Mode = .normal, stored: KopiaPolicyDocument? = nil) { self.mode = mode; self.stored = stored }

    func policyDefinition(source: KopiaSnapshotSource) async throws -> KopiaSourcePolicyDefinition? {
        reads += 1
        if mode == .foreignSelector {
            return KopiaSourcePolicyDefinition(
                source: try KopiaSnapshotSource(userName: "other", host: source.host, path: source.path),
                document: KopiaPolicyDocument())
        }
        if mode == .localConflict && reads == 2 {
            stored = try KopiaPolicyDocument(data: Data(#"{"future":true}"#.utf8))
        }
        return stored.map { KopiaSourcePolicyDefinition(source: source, document: $0) }
    }

    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) async throws -> KopiaPolicyDocument {
        previews += 1
        if mode == .blockedPreview, previews == 1 {
            await withCheckedContinuation {
                blocked = $0; observer?.resume(); observer = nil
            }
        }
        try Task.checkCancellation()
        var result = updates ?? stored ?? KopiaPolicyDocument()
        switch mode {
        case .parentConflict where previews == 2:
            result = try KopiaPolicyDocument(data: result.encoded().dropLast() + Data(",\"future\":true}".utf8))
        case .inheritedIgnore: try result.updateSection("files", values: ["ignore": Data(#"["inherited/"]"#.utf8)])
        case .inheritedSize: try result.updateSection("files", values: ["maxFileSize": Data("42".utf8)])
        case .inheritedSchedule: try result.updateSection("scheduling", values: ["intervalSeconds": Data("3600".utf8)])
        default: break
        }
        return result
    }

    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) async throws {
        writes += 1
        stored = document
        if mode == .postWriteConflict { stored = try KopiaPolicyDocument(data: Data("{}".utf8)) }
        if mode == .uncertainWrite { throw PolicySynchronizationError.verificationFailed }
    }
}
