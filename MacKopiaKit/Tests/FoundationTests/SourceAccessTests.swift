import BackupDomain
import BackupEngine
import Darwin
import Foundation
import SystemIntegration
import Testing

struct SourceAccessTests {
    @Test func nativeReadsObserveFreshContentsAndNeverCreateMissingPaths() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = LocalReadAccessProbe()
        #expect(try await reader.readDirectory(at: root.path) == .readable)
        let file = root.appendingPathComponent("protected-probe")
        #expect(try await reader.readFile(at: file.path) == .missing)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try Data().write(to: file)
        #expect(try await reader.readFile(at: file.path) == .readable)
        try Data([1, 2, 3]).write(to: file)
        #expect(try await reader.readFile(at: file.path) == .readable)
        #expect(try await reader.readFile(at: root.path) == .unknown)
        #expect(try await reader.readDirectory(at: file.path) == .unknown)
        try FileManager.default.removeItem(at: file)
        #expect(try await reader.readFile(at: file.path) == .missing)
        #expect(try await reader.readDirectory(at: file.path) == .missing)
    }

    @Test func nativeProbeRejectsFinalSymlinksSpecialFilesAndInvalidPaths() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([1]).write(to: file)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        let reader = LocalReadAccessProbe()
        #expect(try await reader.readFile(at: alias.path) == .unknown)
        #expect(try await reader.readFile(at: fifo.path) == .unknown)
        for path in ["relative", "/Source/../Other", "/Source\0Other"] {
            #expect(try await reader.readFile(at: path) == .unknown)
            #expect(try await reader.readDirectory(at: path) == .unknown)
        }
    }

    @Test func nativePermissionDenialIsDistinctFromMissingData() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("unreadable-file")
        let directory = root.appendingPathComponent("unreadable-directory")
        try Data([1]).write(to: file)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        #expect(chmod(file.path, 0) == 0)
        #expect(chmod(directory.path, 0) == 0)
        defer {
            _ = chmod(file.path, 0o600)
            _ = chmod(directory.path, 0o700)
        }
        let reader = LocalReadAccessProbe()
        #expect(try await reader.readFile(at: file.path) == .denied)
        #expect(try await reader.readDirectory(at: directory.path) == .denied)
    }

    @Test func protectedProbeUsesOnlyItsInjectedHome() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = LocalFullDiskAccessProbe(home: root)
        #expect(try await probe.probe() == .unknown)
        let mail = root.appendingPathComponent("Library/Mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        #expect(try await probe.probe() == .readable)
        try FileManager.default.removeItem(at: mail)
        let bookmarks = root.appendingPathComponent("Library/Safari/Bookmarks.plist")
        try FileManager.default.createDirectory(
            at: bookmarks.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: bookmarks)
        #expect(try await probe.probe() == .readable)
    }

    @Test func protectedProbeFallsBackOnlyWhenPrimaryIsMissingAndNeverCaches() async throws {
        let reader = AccessProbeStub(file: .missing, directory: .readable)
        let probe = LocalFullDiskAccessProbe(home: URL(fileURLWithPath: "/SyntheticHome"), reader: reader)
        #expect(!String(reflecting: probe).contains("SyntheticHome"))
        #expect(try await probe.probe() == .readable)
        #expect(
            await reader.calls == [
                "file:/SyntheticHome/Library/Safari/Bookmarks.plist", "directory:/SyntheticHome/Library/Mail",
            ])
        await reader.setFile(.denied)
        #expect(try await probe.probe() == .denied)
        #expect(await reader.calls.count == 3)
        await reader.setFile(.unknown)
        #expect(try await probe.probe() == .unknown)
        #expect(await reader.calls.count == 4)
        await reader.setFile(.readable)
        #expect(try await probe.probe() == .readable)
        #expect(await reader.calls.count == 5)
    }

    @Test func missingProtectedDataDoesNotEstablishAccess() async throws {
        for (observation, expected) in [
            (ReadAccessObservation.missing, FullDiskAccessObservation.unknown), (.unknown, .unknown),
            (.denied, .denied),
        ] {
            let reader = AccessProbeStub(file: .missing, directory: observation)
            let probe = LocalFullDiskAccessProbe(home: URL(fileURLWithPath: "/SyntheticHome"), reader: reader)
            #expect(try await probe.probe() == expected)
        }
    }

    @Test func everySourceRequiresFreshReadAndProtectedEvidence() async throws {
        let sources = try PreflightTestFixture().plan.sources
        let reader = AccessProbeStub()
        let checker = LocalSourceAccessChecker(fullDiskAccess: reader, reader: reader)
        #expect(try await checker.checkAccess(to: sources) == .verified)
        #expect(await reader.calls == ["protected"] + sources.map { "directory:" + $0.path })
        await reader.setDirectory(.denied, at: sources[1].path)
        #expect(try await checker.checkAccess(to: sources) == .denied)
        await reader.setDirectory(.missing, at: sources[1].path)
        #expect(try await checker.checkAccess(to: sources) == .unknown)
        await reader.setDirectory(.unknown, at: sources[1].path)
        #expect(try await checker.checkAccess(to: sources) == .unknown)
    }

    @Test func absentSourcesOrUnconfirmedProtectedAccessNeverReadSources() async throws {
        let sources = try PreflightTestFixture().plan.sources
        for (observation, expected) in [
            (FullDiskAccessObservation.unknown, PreflightAccessStatus.unknown), (.denied, .denied),
        ] {
            let reader = AccessProbeStub(protected: observation)
            let checker = LocalSourceAccessChecker(fullDiskAccess: reader, reader: reader)
            #expect(try await checker.checkAccess(to: []) == .unknown)
            #expect(await reader.calls.isEmpty)
            #expect(try await checker.checkAccess(to: sources) == expected)
            #expect(await reader.calls == ["protected"])
        }
    }

    @Test func cancellationIsPreservedBeforeAndAfterAdapterSuspension() async throws {
        let sources = try PreflightTestFixture().plan.sources
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let reader = AccessProbeStub()
            let checker = LocalSourceAccessChecker(fullDiskAccess: reader, reader: reader)
            await #expect(throws: CancellationError.self) { try await checker.checkAccess(to: sources) }
            await #expect(throws: CancellationError.self) { try await LocalReadAccessProbe().readFile(at: "/unused") }
            await #expect(throws: CancellationError.self) {
                try await LocalReadAccessProbe().readDirectory(at: "/unused")
            }
            await #expect(throws: CancellationError.self) { try await LocalFullDiskAccessProbe(reader: reader).probe() }
            #expect(await reader.calls.isEmpty)
        }
        await cancelled.value
        let reader = AccessProbeStub(cancelOnRead: true)
        let task = Task {
            let checker = LocalSourceAccessChecker(fullDiskAccess: reader, reader: reader)
            await #expect(throws: CancellationError.self) { try await checker.checkAccess(to: sources) }
        }
        await task.value
        #expect(await reader.calls.count == 2)
    }
}

private actor AccessProbeStub: ReadAccessProbing, FullDiskAccessProbing {
    var calls: [String] = []
    private var file: ReadAccessObservation
    private var directory: ReadAccessObservation
    private var directories: [String: ReadAccessObservation] = [:]
    private let protected: FullDiskAccessObservation
    private let cancelOnRead: Bool

    init(
        file: ReadAccessObservation = .readable, directory: ReadAccessObservation = .readable,
        protected: FullDiskAccessObservation = .readable, cancelOnRead: Bool = false
    ) {
        self.file = file
        self.directory = directory
        self.protected = protected
        self.cancelOnRead = cancelOnRead
    }
    func setFile(_ value: ReadAccessObservation) { file = value }
    func setDirectory(_ value: ReadAccessObservation, at path: String) { directories[path] = value }
    func readFile(at path: String) async throws -> ReadAccessObservation {
        calls.append("file:" + path)
        return file
    }
    func readDirectory(at path: String) async throws -> ReadAccessObservation {
        calls.append("directory:" + path)
        if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        return directories[path] ?? directory
    }
    func probe() async throws -> FullDiskAccessObservation {
        calls.append("protected")
        return protected
    }
}
