import AppKit
import Testing

@testable import SystemIntegration

@Suite(.serialized)
struct SystemEventMonitorTests {
    @Test @MainActor func cancelledObservationNeverOpensNativeRegistrations() async {
        let monitor = LocalSystemEventMonitor(openNative: {
            Issue.record("Cancelled observation opened native registrations")
            return try await NativeSystemEventSession()
        })
        let observing = Task { try await monitor.observe { _ in } }
        observing.cancel()
        await #expect(throws: CancellationError.self) { try await observing.value }
    }

    @Test @MainActor func releasingSessionClosesNativeRegistrations() throws {
        var session: NativeSystemEventSession? = try NativeSystemEventSession(
            workspaceCenter: NotificationCenter(), defaultCenter: NotificationCenter())
        let id = try #require(session?.callbackID)
        session = nil
        #expect(SystemEventCallbackRegistry.session(for: id) == nil)
        systemPowerChanged(UnsafeMutableRawPointer(bitPattern: id))
    }

    @Test @MainActor func nativeNotificationsUseTheirOwnCentersAndCloseInvalidatesCallbacks() async throws {
        let workspace = NotificationCenter()
        let system = NotificationCenter()
        let session = try NativeSystemEventSession(workspaceCenter: workspace, defaultCenter: system)
        let id = try #require(session.callbackID)
        system.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        system.post(name: .NSSystemClockDidChange, object: nil)
        system.post(name: .NSSystemTimeZoneDidChange, object: nil)
        session.close()
        session.close()
        #expect(SystemEventCallbackRegistry.session(for: id) == nil)
        // A C notification queued before close must never recover its released owner.
        systemPowerChanged(UnsafeMutableRawPointer(bitPattern: id))
        workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        var events: [SystemEvent] = []
        for try await event in session.events { events.append(event) }
        #expect(events.filter { $0 == .woke }.count == 1)
        #expect(events.filter { $0 == .clockChanged }.count == 1)
        #expect(events.filter { $0 == .timeZoneChanged }.count == 1)
        #expect(events.filter { if case .power = $0 { true } else { false } }.count == 1)
        #expect(session.closed)
    }

    @Test @MainActor func mountEdgesDeduplicateByUUIDAndNeverPublishMountNames() async throws {
        let session = try NativeSystemEventSession(
            workspaceCenter: NotificationCenter(), defaultCenter: NotificationCenter())
        let first = UUID().uuidString
        let second = UUID().uuidString
        let path = "/private-synthetic-mount-marker"
        session.mounted(path: path, uuid: "invalid")
        session.mounted(path: path, uuid: first.lowercased())
        session.mounted(path: path, uuid: first)
        session.mounted(path: path, uuid: second)
        session.unmounted(path: path, expectedUUID: first)
        session.unmounted(path: path)
        session.unmounted(path: path)
        session.close()
        session.mounted(path: path, uuid: first)
        var volumes: [SystemEvent] = []
        for try await event in session.events {
            switch event {
            case .volumeMounted, .volumeUnmounted: volumes.append(event)
            default: break
            }
        }
        #expect(
            volumes == [
                .volumeMounted(uuid: first), .volumeUnmounted(uuid: first), .volumeMounted(uuid: second),
                .volumeUnmounted(uuid: second),
            ])
        #expect(!String(reflecting: volumes).contains(path))
    }

    @Test @MainActor func overwhelmedConsumerReceivesFailureInsteadOfSilentlyLosingWakeEdges() async throws {
        let center = NotificationCenter()
        let session = try NativeSystemEventSession(workspaceCenter: center, defaultCenter: NotificationCenter())
        for _ in 0..<300 { center.post(name: NSWorkspace.didWakeNotification, object: nil) }
        session.close()
        var count = 0
        do {
            for try await _ in session.events { count += 1 }
            Issue.record("Overflow must end observation with an error")
        } catch {
            #expect(error is SystemMonitoringError)
        }
        #expect(count == 256)
    }

    @Test @MainActor func realStreamsReportInitialPowerAndNetworkThenCancellationJoinsCleanup() async throws {
        let session = try NativeSystemEventSession(
            workspaceCenter: NotificationCenter(), defaultCenter: NotificationCenter())
        let id = try #require(session.callbackID)
        let received = SystemEventsReceived()
        let monitor = LocalSystemEventMonitor(openNative: { session })
        let observing = Task {
            try await monitor.observe { event in await received.record(event) }
        }
        do {
            try await wait { await received.hasPowerAndNetwork }
        } catch {
            observing.cancel()
            _ = await observing.result
            throw error
        }
        observing.cancel()
        await #expect(throws: CancellationError.self) { try await observing.value }
        #expect(session.closed)
        #expect(SystemEventCallbackRegistry.session(for: id) == nil)
    }

    @Test @MainActor func unexpectedNativeEndStopsTheWholeObservation() async throws {
        let session = try NativeSystemEventSession(
            workspaceCenter: NotificationCenter(), defaultCenter: NotificationCenter())
        let received = SystemEventsReceived()
        let monitor = LocalSystemEventMonitor(openNative: { session })
        let observing = Task { try await monitor.observe { event in await received.record(event) } }
        do {
            try await wait { await received.hasPowerAndNetwork }
        } catch {
            observing.cancel()
            _ = await observing.result
            throw error
        }
        session.close()
        await #expect(throws: SystemMonitoringError.self) { try await observing.value }
        #expect(session.closed)
    }

    @Test func unavailableNetworkDoesNotAttestToCostOrDestinationReachability() {
        let available = NetworkPathObservation(isExpensive: false, isConstrained: false)
        let offline = SystemNetworkObservation(isAvailable: false, path: available, interfaces: [.wifi])
        #expect(offline.path == NetworkPathObservation())
        #expect(offline.isAvailable == false)
        #expect(offline.interfaces == [.wifi])
    }

    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }
}

private actor SystemEventsReceived {
    private var power = false
    private var network = false
    var hasPowerAndNetwork: Bool { power && network }
    func record(_ event: SystemEvent) {
        if case .power = event { power = true }
        if case .network = event { network = true }
    }
}
