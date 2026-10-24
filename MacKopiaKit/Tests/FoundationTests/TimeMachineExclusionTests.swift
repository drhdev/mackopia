import BackupDomain
import Darwin
import Foundation
import SystemIntegration
import Testing

@testable import BackupEngine

struct TimeMachineExclusionTests {
    private let uuid = "11111111-1111-1111-1111-111111111111"

    private func source(path: String = "/fixture") throws -> BackupSource {
        try BackupSource(
            path: path,
            volume: VolumeIdentity(uuid: uuid, name: "Fixture", isRemovable: false, isNetwork: false))
    }

    private func entry(
        excluded: Bool = false, directory: Bool = true, symlink: Bool = false, volume: String? = nil
    ) -> TimeMachineExclusionEntry {
        TimeMachineExclusionEntry(
            volumeUUID: volume ?? uuid, isDirectory: directory, isSymbolicLink: symlink, isExcluded: excluded)
    }

    @Test func escapesAnchorsAndStopsAtExcludedDirectories() async throws {
        let inspector = TimeMachineFixtureInspector(
            entries: ["/fixture": entry(), "/fixture/[x]*?\\": entry(excluded: true)],
            childNames: ["/fixture": ["[x]*?\\"]])
        let result = try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: source())
        let boundSource = try source()
        // Source UUIDs differ even when paths match: reuse requires the original complete source.
        #expect(throws: TimeMachineExclusionError.staleResult) { try result.patterns(for: boundSource) }
        let stableSource = try source()
        let stable = try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: stableSource)
        #expect(try stable.patterns(for: stableSource) == ["/\\[x\\]\\*\\?\\\\/"])
        #expect(await inspector.inspectedPaths() == ["/fixture", "/fixture/[x]*?\\", "/fixture", "/fixture/[x]*?\\"])
    }

    @Test func depthVolumeAndSymlinkBoundariesAreNeverTraversed() async throws {
        let inspector = TimeMachineFixtureInspector(
            entries: [
                "/fixture": entry(), "/fixture/a": entry(), "/fixture/a/b": entry(),
                "/fixture/a/b/c": entry(), "/fixture/link": entry(symlink: true),
                "/fixture/mount": entry(volume: "22222222-2222-2222-2222-222222222222"),
            ],
            childNames: ["/fixture": ["a", "link", "mount"], "/fixture/a": ["b"], "/fixture/a/b": ["c"]])
        let stableSource = try source()
        let snapshot = try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: stableSource)
        #expect(try snapshot.patterns(for: stableSource).isEmpty)
        #expect(await inspector.listedPaths() == ["/fixture", "/fixture/a", "/fixture/a/b"])
    }

    @Test func excludesRootAndRejectsChangedSourceAndExpiredCache() async throws {
        let stableSource = try source()
        let instant = ContinuousClock.now
        let inspector = TimeMachineFixtureInspector(entries: ["/fixture": entry(excluded: true)])
        let snapshot = try await TimeMachineExclusionResolver(inspector: inspector, now: { instant })
            .resolve(for: stableSource)
        #expect(try snapshot.patterns(for: stableSource, now: instant) == ["**"])
        #expect(throws: TimeMachineExclusionError.staleResult) {
            try snapshot.patterns(for: stableSource, now: instant.advanced(by: .seconds(61)))
        }
        #expect(throws: TimeMachineExclusionError.staleResult) {
            try snapshot.patterns(for: stableSource, now: instant.advanced(by: .seconds(-1)))
        }
        #expect(await inspector.listedPaths().isEmpty)
    }

    @Test func unreadableEntriesAndOversizedScansNeverReturnPartialPatterns() async throws {
        let inspector = TimeMachineFixtureInspector(
            entries: ["/fixture": entry(), "/fixture/excluded": entry(excluded: true)],
            childNames: ["/fixture": ["excluded", "unreadable"]])
        await #expect(throws: TimeMachineExclusionError.unavailable) {
            try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: source())
        }
        await #expect(throws: TimeMachineExclusionError.limitExceeded) {
            try await TimeMachineExclusionResolver(inspector: inspector, entryLimit: 2).resolve(for: source())
        }
    }

    @Test(arguments: ["..", "a/b", "new\nline"])
    func rejectsMalformedChildNames(name: String) async throws {
        let inspector = TimeMachineFixtureInspector(
            entries: ["/fixture": entry()], childNames: ["/fixture": [name]])
        await #expect(throws: TimeMachineExclusionError.invalidSource) {
            try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: source())
        }
    }

    @Test func rejectsRootIdentityMismatchAndCancellation() async throws {
        let inspector = TimeMachineFixtureInspector(
            entries: ["/fixture": entry(volume: "22222222-2222-2222-2222-222222222222")])
        await #expect(throws: DomainValidationError.volumeMismatch) {
            try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: source())
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: source())
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func detectsDeadlineExceededDuringInspection() async throws {
        let instant = ContinuousClock.now
        let inspector = TimeMachineFixtureInspector(
            entries: ["/fixture": entry()], delay: .milliseconds(20))
        await #expect(throws: TimeMachineExclusionError.limitExceeded) {
            try await TimeMachineExclusionResolver(inspector: inspector, timeout: .milliseconds(1), now: { .now })
                .resolve(for: source())
        }
        #expect(instant <= .now)
    }

    @Test func rejectsCrossVolumeCoverageAndRedactsReflection() async throws {
        let stableSource = try source()
        let metadata = entry(excluded: true)
        let inspector = TimeMachineFixtureInspector(entries: ["/fixture": metadata])
        await #expect(throws: TimeMachineExclusionError.invalidSource) {
            try await TimeMachineExclusionResolver(inspector: inspector).resolve(
                for: stableSource, oneFileSystem: false)
        }
        let snapshot = try await TimeMachineExclusionResolver(inspector: inspector).resolve(for: stableSource)
        #expect(!String(reflecting: snapshot).contains("/fixture"))
        #expect(!String(reflecting: metadata).contains(uuid))
        #expect(Mirror(reflecting: snapshot).children.count == 1)
    }

    @Test func nativeMissingPathMapsToStaticError() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        await #expect(throws: TimeMachineExclusionError.unavailable) {
            try await TimeMachineLocalExclusionInspector().inspect(missing.path)
        }
    }

    @Test func nativeAdapterReadsStickyExclusionOnlyInTemporaryFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marked = directory.appendingPathComponent("marked")
        try FileManager.default.createDirectory(at: marked, withIntermediateDirectories: false)
        let value = Data("com.apple.backupd".utf8)
        let status = value.withUnsafeBytes { bytes in
            marked.path.withCString { path in
                setxattr(path, "com.apple.metadata:com_apple_backup_excludeItem", bytes.baseAddress, bytes.count, 0, 0)
            }
        }
        #expect(status == 0)
        let inspector = TimeMachineLocalExclusionInspector()
        let baseline = try await inspector.inspect(directory.path)
        #expect(!baseline.isExcluded)
        let metadata = try await inspector.inspect(marked.path)
        #expect(metadata.isExcluded)
        #expect(try await inspector.children(of: directory.path, limit: 1) == ["marked"])
    }
}

private actor TimeMachineFixtureInspector: TimeMachineExclusionInspecting {
    let entries: [String: TimeMachineExclusionEntry]
    let childNames: [String: [String]]
    let delay: Duration
    private var inspected: [String] = []
    private var listed: [String] = []

    init(entries: [String: TimeMachineExclusionEntry], childNames: [String: [String]] = [:], delay: Duration = .zero) {
        self.entries = entries
        self.childNames = childNames
        self.delay = delay
    }

    func inspect(_ path: String) async throws -> TimeMachineExclusionEntry {
        inspected.append(path)
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let entry = entries[path] else { throw TimeMachineExclusionError.unavailable }
        return entry
    }

    func children(of path: String, limit: Int) async throws -> [String] {
        listed.append(path)
        return childNames[path] ?? []
    }

    func inspectedPaths() -> [String] { inspected }
    func listedPaths() -> [String] { listed }
}
