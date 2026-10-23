import BackupDomain
import BackupEngine
import DiskArbitration
import Foundation
import Testing

@testable import SystemIntegration

struct VolumeProtectionTests {
    @Test func successClosesObservationAndIncludesSourceAndDestination() async throws {
        let fixture = try PreflightTestFixture()
        let session = TestVolumeSession()
        let monitor = TestVolumeMonitor(session: session)
        let protection = LocalBackupOperationProtection(monitor: monitor)
        let value = try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
            42
        }
        #expect(value == 42)
        #expect(await session.closed)
        #expect(await monitor.paths == fixture.plan.sources.map(\.path) + ["/Destination"])
        #expect(await monitor.identities == Array(repeating: fixture.plan.sources[0].volume.uuid, count: 3))
    }

    @Test func disappearanceCancelsOperationAndWaitsForCleanupBeforeClosingMonitor() async throws {
        let fixture = try PreflightTestFixture()
        let session = TestVolumeSession()
        let entered = ProtectionSignal()
        let cleaning = ProtectionSignal()
        let finishCleanup = ProtectionSignal()
        let protection = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session))
        let task = Task {
            try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
                await entered.signal()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await cleaning.signal()
                    await finishCleanup.wait()
                    throw error
                }
            }
        }
        await entered.wait()
        await session.disappear()
        await cleaning.wait()
        #expect(await !session.closed)
        await finishCleanup.signal()
        await #expect(throws: BackupOperationError.volumeDisappeared) { try await task.value }
        #expect(await session.closed)
    }

    @Test func unexpectedObserverEndCancelsRatherThanLettingOperationContinue() async throws {
        let fixture = try PreflightTestFixture()
        let session = TestVolumeSession()
        let entered = ProtectionSignal()
        let protection = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session))
        let task = Task {
            try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
                await entered.signal()
                try await Task.sleep(for: .seconds(60))
            }
        }
        await entered.wait()
        await session.finishUnexpectedly()
        await #expect(throws: BackupOperationError.protectionUnavailable) { try await task.value }
        #expect(await session.closed)
    }

    @Test func priorDisappearanceAndRegistrationFailureNeverExecute() async throws {
        let fixture = try PreflightTestFixture()
        let session = TestVolumeSession()
        await session.disappear()
        let protection = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session))
        await #expect(throws: BackupOperationError.volumeDisappeared) {
            try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
                Issue.record("Operation entered after volume disappearance")
            }
        }
        #expect(await session.closed)
        let failed = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session, fails: true))
        await #expect(throws: BackupOperationError.protectionUnavailable) {
            try await failed.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
                Issue.record("Operation entered without a monitor")
            }
        }
    }

    @Test func cancellationAndOperationFailureAlwaysCloseObservation() async throws {
        let fixture = try PreflightTestFixture()
        for cancel in [true, false] {
            let session = TestVolumeSession()
            let entered = ProtectionSignal()
            let protection = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session))
            let task = Task {
                try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) {
                    await entered.signal()
                    if cancel {
                        try await Task.sleep(for: .seconds(60))
                    } else {
                        throw BackupOperationError.operationFailed
                    }
                }
            }
            await entered.wait()
            if cancel { task.cancel() }
            do { try await task.value; Issue.record("Expected operation failure") } catch {
                #expect(cancel ? error is CancellationError : error as? BackupOperationError == .operationFailed)
            }
            #expect(await session.closed)
        }
    }

    @Test func sourcesThatAppearWhileArmingCannotEscapeProtectionCoverage() async throws {
        let fixture = try PreflightTestFixture(scenario: .init(missingSources: ["/Source"]))
        let session = TestVolumeSession()
        let monitor = TestVolumeMonitor(session: session, arm: { await fixture.probe.updateScenario(.init()) })
        let coordinator = BackupOperationCoordinator(
            preflight: fixture.preflight, protection: LocalBackupOperationProtection(monitor: monitor))
        await #expect(throws: BackupOperationError.identitiesChanged) {
            try await coordinator.perform(plan: fixture.plan, repository: fixture.repository) { _ in
                Issue.record("New source escaped monitoring coverage")
            }
        }
        #expect(await monitor.paths == ["/Other", "/Destination"])
        #expect(await session.closed)
    }

    @Test func latchedDisappearanceAfterOperationCannotBecomeSuccess() async throws {
        let fixture = try PreflightTestFixture()
        let session = TestVolumeSession(failAtCheck: 3)
        let protection = LocalBackupOperationProtection(monitor: TestVolumeMonitor(session: session))
        await #expect(throws: BackupOperationError.volumeDisappeared) {
            try await protection.withProtection(sources: fixture.plan.sources, repository: fixture.repository) { 42 }
        }
        #expect(await session.closed)
    }

    @Test func invalidRequestsAndWrongCFTypesAreRejected() throws {
        for path in ["relative", "/a/../b", "/a\0b"] {
            #expect(throws: VolumeProtectionError.unavailable) {
                try ProtectedDirectory(path: path, volumeUUID: UUID().uuidString)
            }
        }
        #expect(throws: VolumeProtectionError.unavailable) { try ProtectedDirectory(path: "/a", volumeUUID: "invalid") }
        #expect(DiskVolumeProtectionSession.uuidString(nil) == nil)
        #expect(DiskVolumeProtectionSession.uuidString("not-a-CFUUID") == nil)
        #expect(DiskVolumeProtectionSession.uuidString(42) == nil)
        let uuid = CFUUIDCreate(nil)
        #expect(DiskVolumeProtectionSession.uuidString(uuid) == CFUUIDCreateString(nil, uuid) as String)
    }

    @Test @MainActor func nativeSessionArmsAndClosesOnTemporaryDirectoryWithoutUnmounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let uuid = try await LocalVolumeInspector().volumeUUID(forDirectory: root.path)
        let request = try ProtectedDirectory(path: root.path, volumeUUID: uuid)
        let started = try await LocalVolumeProtectionMonitor().start(directories: [request, request])
        let session = try #require(started as? DiskVolumeProtectionSession)
        try await session.checkActive()
        let token = try VolumeProtectionCallbackRegistry.insert(session)
        #expect(VolumeProtectionCallbackRegistry.session(for: token) === session)
        VolumeProtectionCallbackRegistry.remove(token)
        #expect(VolumeProtectionCallbackRegistry.session(for: token) == nil)
        let nextToken = try VolumeProtectionCallbackRegistry.insert(session)
        #expect(nextToken != token)
        let query = try #require(DASessionCreate(nil))
        let mount = try LocalVolumeMount(directory: root)
        let disk = try #require(mount.device.withCString { DADiskCreateFromBSDName(nil, query, $0) })
        #expect(session.blocksUnmount(disk))
        #expect(volumeUnmountApproval(disk, UnsafeMutableRawPointer(bitPattern: token)) == nil)
        let denial = try #require(volumeUnmountApproval(disk, UnsafeMutableRawPointer(bitPattern: nextToken)))
        #expect(DADissenterGetStatus(denial.takeRetainedValue()) == DAReturn(kDAReturnBusy))
        session.observeDescription(disk)
        try await session.checkActive()
        // Exercise the callback's state transition without issuing an unmount/eject operation.
        volumeDisappeared(disk, UnsafeMutableRawPointer(bitPattern: nextToken))
        var iterator = session.events.makeAsyncIterator()
        #expect(await iterator.next() == .disappeared)
        #expect(await iterator.next() == nil)
        await #expect(throws: VolumeProtectionError.volumeDisappeared) { try await session.checkActive() }
        #expect(session.blocksUnmount(disk))
        await session.close()
        await session.close()
        #expect(!session.blocksUnmount(disk))
        VolumeProtectionCallbackRegistry.remove(nextToken)
        #expect(volumeUnmountApproval(disk, UnsafeMutableRawPointer(bitPattern: nextToken)) == nil)
        await #expect(throws: VolumeProtectionError.unavailable) { try await session.checkActive() }
        let wrong = try ProtectedDirectory(path: root.path, volumeUUID: UUID().uuidString)
        await #expect(throws: VolumeProtectionError.unavailable) {
            try await LocalVolumeProtectionMonitor().start(directories: [wrong])
        }
        await #expect(throws: VolumeProtectionError.unavailable) {
            try await LocalVolumeProtectionMonitor().start(directories: [])
        }
    }
}

private actor TestVolumeMonitor: VolumeProtectionStarting {
    let session: TestVolumeSession
    let fails: Bool
    let arm: @Sendable () async -> Void
    private(set) var paths: [String] = []
    private(set) var identities: [String] = []
    init(session: TestVolumeSession, fails: Bool = false, arm: @escaping @Sendable () async -> Void = {}) {
        self.session = session
        self.fails = fails
        self.arm = arm
    }
    func start(directories: [ProtectedDirectory]) async throws -> any VolumeProtectionSession {
        if fails { throw VolumeProtectionError.unavailable }
        paths = directories.map(\.path)
        identities = directories.map(\.volumeUUID)
        await arm()
        return session
    }
}

private actor TestVolumeSession: VolumeProtectionSession {
    nonisolated let events: AsyncStream<VolumeProtectionEvent>
    private let continuation: AsyncStream<VolumeProtectionEvent>.Continuation
    private(set) var closed = false
    private var disappeared = false
    private var checks = 0
    private let failAtCheck: Int?
    init(failAtCheck: Int? = nil) {
        self.failAtCheck = failAtCheck
        let stream = AsyncStream<VolumeProtectionEvent>.makeStream()
        events = stream.stream
        continuation = stream.continuation
    }
    func checkActive() async throws {
        try Task.checkCancellation()
        checks += 1
        if checks == failAtCheck { disappeared = true }
        if disappeared { throw VolumeProtectionError.volumeDisappeared }
        if closed { throw VolumeProtectionError.unavailable }
    }
    func close() async { closed = true; continuation.finish() }
    func disappear() { disappeared = true; continuation.yield(.disappeared); continuation.finish() }
    func finishUnexpectedly() { continuation.finish() }
}

private actor ProtectionSignal {
    var signalled = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
