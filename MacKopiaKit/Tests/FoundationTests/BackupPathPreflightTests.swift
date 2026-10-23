import BackupDomain
import BackupEngine
import Foundation
import Synchronization
import SystemIntegration
import Testing

struct BackupPathPreflightTests {
    private func volume(_ uuid: UUID = UUID()) throws -> VolumeIdentity {
        try VolumeIdentity(uuid: uuid.uuidString, name: "Test", isRemovable: true, isNetwork: false)
    }

    private func source(_ path: String, volume: VolumeIdentity) throws -> BackupSource {
        try BackupSource(path: path, volume: volume)
    }

    private func repository(_ path: String = "/Destination", volume: VolumeIdentity?) throws -> Repository {
        try Repository(
            name: "Test", kind: .filesystem(path: path, volume: volume),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
    }

    private func plan(_ sources: [BackupSource], repository: Repository) throws -> BackupPlan {
        try BackupPlan(
            name: "Test", isEnabled: true, repositoryID: repository.id, sources: sources, triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: false, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }

    private func observation(
        _ path: String, volume: VolumeIdentity, caseSensitive: Bool = true
    ) throws -> DirectoryObservation {
        try DirectoryObservation(canonicalPath: path, volumeUUID: volume.uuid, isCaseSensitive: caseSensitive)
    }

    @Test func validPathsInspectDestinationFirstAndPreserveSourceOrder() async throws {
        let volume = try volume()
        let repository = try repository(volume: volume)
        let sources = try [source("/Source", volume: volume), source("/Source-archive", volume: volume)]
        let inspector = RecordingDirectories([
            "/Destination": .success(try observation("/Destination", volume: volume)),
            "/Source": .success(try observation("/Source", volume: volume)),
            "/Source-archive": .success(try observation("/Source-archive", volume: volume)),
        ])
        let statuses = try await BackupPathPreflight(inspector: inspector).validate(
            plan: plan(sources, repository: repository), repository: repository)
        #expect(statuses == sources.map { .ready(sourceID: $0.id) })
        #expect(inspector.paths == ["/Destination", "/Source", "/Source-archive"])
    }

    @Test func overlappingRawPathsOrUnboundDestinationFailBeforeIO() async throws {
        let volume = try volume()
        let inspector = RecordingDirectories([:])
        let preflight = BackupPathPreflight(inspector: inspector)
        for (paths, destination, error) in [
            (["/Source", "/Source/Nested"], "/Destination", BackupPreflightError.overlappingSources),
            (["/Source"], "/Source/Backup", .sourceDestinationOverlap),
            (["/Destination/Source"], "/Destination", .sourceDestinationOverlap),
            (["/Destination"], "/Destination", .sourceDestinationOverlap),
            (["/"], "/Destination", .sourceDestinationOverlap),
        ] {
            let repository = try repository(destination, volume: volume)
            let plan = try plan(paths.map { try source($0, volume: volume) }, repository: repository)
            await #expect(throws: error) { try await preflight.validate(plan: plan, repository: repository) }
        }
        let unbound = try repository(volume: nil)
        let plan = try plan([source("/Source", volume: volume)], repository: unbound)
        await #expect(throws: BackupPreflightError.unboundDestination) {
            try await preflight.validate(plan: plan, repository: unbound)
        }
        let other = try repository(volume: volume)
        await #expect(throws: BackupPreflightError.repositoryMismatch) {
            try await preflight.validate(plan: plan, repository: other)
        }
        #expect(inspector.paths.isEmpty)
    }

    @Test func wrongOrUnavailableDestinationNeverInspectsSources() async throws {
        let volume = try volume()
        let repository = try repository(volume: volume)
        let plan = try plan([source("/Source", volume: volume)], repository: repository)
        for (response, error): (Result<DirectoryObservation, any Error>, BackupPreflightError) in [
            (.success(try observation("/Destination", volume: self.volume())), .destinationVolumeMismatch),
            (.failure(VolumeInspectionError.unavailable), .destinationUnavailable),
            (.failure(VolumeInspectionError.permissionDenied), .destinationPermissionDenied),
        ] {
            let inspector = RecordingDirectories(["/Destination": response])
            await #expect(throws: error) {
                try await BackupPathPreflight(inspector: inspector).validate(plan: plan, repository: repository)
            }
            #expect(inspector.paths == ["/Destination"])
        }
    }

    @Test func absentWrongVolumeAndDeniedSourcesAreSkippedWithoutEmptySnapshotApproval() async throws {
        let volume = try volume()
        let repository = try repository(volume: volume)
        let sources = try [
            source("/Missing", volume: volume), source("/Wrong", volume: volume), source("/Denied", volume: volume),
        ]
        let inspector = RecordingDirectories([
            "/Destination": .success(try observation("/Destination", volume: volume)),
            "/Wrong": .success(try observation("/Wrong", volume: self.volume())),
            "/Denied": .failure(VolumeInspectionError.permissionDenied),
        ])
        #expect(
            try await BackupPathPreflight(inspector: inspector).validate(
                plan: plan(sources, repository: repository), repository: repository)
                == [
                    .skipped(sourceID: sources[0].id, reason: .unavailable),
                    .skipped(sourceID: sources[1].id, reason: .volumeMismatch),
                    .skipped(sourceID: sources[2].id, reason: .permissionDenied),
                ])
    }

    @Test func symlinkAliasesAndCaseInsensitiveResolvedPathsCannotHideOverlaps() async throws {
        let volume = try volume()
        let repository = try repository(volume: volume)
        for (sources, canonical, error) in [
            (["/Alias"], ["/destination/Nested"], BackupPreflightError.sourceDestinationOverlap),
            (["/First", "/Second"], ["/Actual", "/actual/Nested"], .overlappingSources),
            (["/First", "/Second"], ["/Actual", "/Actual"], .overlappingSources),
        ] {
            var responses: [String: Result<DirectoryObservation, any Error>] = [
                "/Destination": .success(try observation("/Destination", volume: volume, caseSensitive: false))
            ]
            for (path, resolved) in zip(sources, canonical) {
                responses[path] = .success(try observation(resolved, volume: volume, caseSensitive: false))
            }
            let inspector = RecordingDirectories(responses)
            let plan = try plan(sources.map { try source($0, volume: volume) }, repository: repository)
            await #expect(throws: error) {
                try await BackupPathPreflight(inspector: inspector).validate(plan: plan, repository: repository)
            }
        }
    }

    @Test func remoteDestinationDoesNotInventLocalDestinationInspection() async throws {
        let volume = try volume()
        let url = try #require(URL(string: "https://example.invalid"))
        let repository = try Repository(
            name: "Test", kind: .webdav(url: url),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
        let source = try source("/Source", volume: volume)
        let inspector = RecordingDirectories(["/Source": .success(try observation("/Source", volume: volume))])
        #expect(
            try await BackupPathPreflight(inspector: inspector).validate(
                plan: plan([source], repository: repository), repository: repository)
                == [.ready(sourceID: source.id)])
        #expect(inspector.paths == ["/Source"])
    }

    @Test func realDirectoriesAndSymlinkAliasUseActualTargetAndVolume() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("Source ü + %2F")
        let destinationURL = root.appendingPathComponent("Destination")
        for url in [sourceURL, destinationURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let observed = try await LocalDirectoryInspector().inspectDirectory(at: destinationURL.path)
        let volume = try volume(#require(UUID(uuidString: observed.volumeUUID)))
        let repository = try repository(destinationURL.path, volume: volume)
        let source = try source(sourceURL.path, volume: volume)
        let preflight = BackupPathPreflight()
        #expect(
            try await preflight.validate(plan: plan([source], repository: repository), repository: repository)
                == [.ready(sourceID: source.id)])
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destinationURL)
        let aliasPlan = try plan([self.source(alias.path, volume: volume)], repository: repository)
        await #expect(throws: BackupPreflightError.sourceDestinationOverlap) {
            try await preflight.validate(plan: aliasPlan, repository: repository)
        }
        let wrong = try self.source(sourceURL.path, volume: self.volume())
        #expect(
            try await preflight.validate(plan: plan([wrong], repository: repository), repository: repository)
                == [.skipped(sourceID: wrong.id, reason: .volumeMismatch)])
        try FileManager.default.removeItem(at: sourceURL)
        #expect(
            try await preflight.validate(plan: plan([source], repository: repository), repository: repository)
                == [.skipped(sourceID: source.id, reason: .unavailable)])
    }

    @Test func cancellationBeforeOrDuringObservationNeverApprovesPaths() async throws {
        let volume = try volume()
        let repository = try repository(volume: volume)
        let plan = try plan([source("/Source", volume: volume)], repository: repository)
        for alreadyCancelled in [false, true] {
            let inspector = RecordingDirectories(
                ["/Destination": .success(try observation("/Destination", volume: volume))], cancel: true)
            let task = Task {
                if alreadyCancelled { withUnsafeCurrentTask { $0?.cancel() } }
                await #expect(throws: CancellationError.self) {
                    try await BackupPathPreflight(inspector: inspector).validate(plan: plan, repository: repository)
                }
            }
            await task.value
            #expect(inspector.paths == (alreadyCancelled ? [] : ["/Destination"]))
        }
    }
}

private final class RecordingDirectories: DirectoryInspecting {
    private let responses: [String: Result<DirectoryObservation, any Error>]
    private let recorded = Mutex<[String]>([])
    private let cancel: Bool
    var paths: [String] { recorded.withLock { $0 } }

    init(_ responses: [String: Result<DirectoryObservation, any Error>], cancel: Bool = false) {
        self.responses = responses
        self.cancel = cancel
    }

    func inspectDirectory(at path: String) async throws -> DirectoryObservation {
        recorded.withLock { $0.append(path) }
        if cancel { withUnsafeCurrentTask { $0?.cancel() } }
        return try (responses[path] ?? .failure(VolumeInspectionError.unavailable)).get()
    }
}
