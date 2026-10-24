import AppKit
import DiskArbitration
import IOKit.ps

/// All native callbacks and teardown are serialized on the main run loop; streams carry values only.
@MainActor
final class NativeSystemEventSession {
    nonisolated let events: AsyncThrowingStream<SystemEvent, any Error>
    private let continuation: AsyncThrowingStream<SystemEvent, any Error>.Continuation
    private let workspaceCenter: NotificationCenter
    private let defaultCenter: NotificationCenter
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var diskSession: DASession?
    private(set) var callbackID: UInt?
    private var volumes: [String: String] = [:]
    private var diskMounts: [String: (path: String, uuid: String)] = [:]
    private var lastPower: PowerStateObservation?
    private(set) var closed = false

    init(
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        defaultCenter: NotificationCenter = .default
    ) throws {
        let stream = AsyncThrowingStream<SystemEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        events = stream.stream
        continuation = stream.continuation
        self.workspaceCenter = workspaceCenter
        self.defaultCenter = defaultCenter
        do {
            try Task.checkCancellation()
            guard let session = DASessionCreate(nil) else { throw SystemMonitoringError.unavailable }
            diskSession = session
            // Seed current mounts so DiskArbitration's initial enumeration is not a new mount trigger.
            for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey])
                ?? []
            {
                if let uuid = volumeUUID(url) { volumes[url.standardizedFileURL.path] = uuid }
            }
            let id = try SystemEventCallbackRegistry.insert(self)
            callbackID = id
            let context = UnsafeMutableRawPointer(bitPattern: id)
            guard let source = IOPSNotificationCreateRunLoopSource(systemPowerChanged, context)?.takeRetainedValue()
            else {
                throw SystemMonitoringError.unavailable
            }
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            DARegisterDiskAppearedCallback(session, nil, systemDiskAppeared, context)
            DARegisterDiskDescriptionChangedCallback(
                session, nil, [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeUUIDKey] as CFArray,
                systemDiskChanged, context)
            DARegisterDiskDisappearedCallback(session, nil, systemDiskDisappeared, context)
            // DiskArbitration requires this queue; all mutable callback state stays MainActor-isolated.
            DASessionSetDispatchQueue(session, .main)
            observe(workspaceCenter, NSWorkspace.didWakeNotification) { $0.emit(.woke) }
            observe(defaultCenter, .NSSystemClockDidChange) { $0.emit(.clockChanged) }
            observe(defaultCenter, .NSSystemTimeZoneDidChange) { $0.emit(.timeZoneChanged) }
            observe(defaultCenter, .NSProcessInfoPowerStateDidChange) { $0.powerChanged() }
            observeVolume(NSWorkspace.didMountNotification, mounted: true)
            observeVolume(NSWorkspace.didUnmountNotification, mounted: false)
            powerChanged()
            try Task.checkCancellation()
        } catch {
            close()
            throw error
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        action: @escaping @MainActor (NativeSystemEventSession) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.closed { action(self) } }
        }
        observers.append((center, token))
    }

    private func observeVolume(_ name: Notification.Name, mounted: Bool) {
        let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
            let url = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                guard let self, !self.closed, let url else { return }
                if mounted {
                    if let uuid = self.volumeUUID(url) { self.mounted(path: url.standardizedFileURL.path, uuid: uuid) }
                } else {
                    // Another native source may already have observed a replacement mount at this path.
                    if let current = self.volumeUUID(url), self.volumes[url.standardizedFileURL.path] == current {
                        return
                    }
                    self.unmounted(path: url.standardizedFileURL.path)
                }
            }
        }
        observers.append((workspaceCenter, token))
    }

    private func volumeUUID(_ url: URL) -> String? {
        var fresh = URL(fileURLWithPath: url.path)
        fresh.removeAllCachedResourceValues()
        if let value = try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
            let uuid = UUID(uuidString: value)
        {
            return uuid.uuidString
        }
        guard let diskSession, let disk = DADiskCreateFromVolumePath(nil, diskSession, fresh as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        return DiskVolumeProtectionSession.uuidString(description[kDADiskDescriptionVolumeUUIDKey as String])
    }

    func diskChanged(_ disk: DADisk, disappeared: Bool = false) {
        guard !closed else { return }
        let device = DADiskGetBSDName(disk).map { String(cString: $0) }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let uuid = DiskVolumeProtectionSession.uuidString(description?[kDADiskDescriptionVolumeUUIDKey as String])
        let url = description?[kDADiskDescriptionVolumePathKey as String] as? URL
        if disappeared || url == nil {
            // A disappeared disk need not retain its description; use its previously observed UUID.
            if let device, let previous = diskMounts.removeValue(forKey: device) {
                unmounted(path: previous.path, expectedUUID: previous.uuid)
            } else if let uuid {
                for path in volumes.filter({ $0.value == uuid }).keys { unmounted(path: path, expectedUUID: uuid) }
            }
        } else if let url, let uuid {
            let path = url.standardizedFileURL.path
            if let device {
                if let previous = diskMounts[device], previous.path != path {
                    unmounted(path: previous.path, expectedUUID: previous.uuid)
                }
                diskMounts[device] = (path, uuid)
            }
            mounted(path: url.standardizedFileURL.path, uuid: uuid)
        }
    }

    func mounted(path: String, uuid: String) {
        guard !closed, let uuid = UUID(uuidString: uuid)?.uuidString, volumes[path] != uuid else { return }
        if let previous = volumes[path] { emit(.volumeUnmounted(uuid: previous)) }
        volumes[path] = uuid
        emit(.volumeMounted(uuid: uuid))
    }

    func unmounted(path: String, expectedUUID: String? = nil) {
        guard !closed, let uuid = volumes[path], expectedUUID == nil || expectedUUID == uuid else { return }
        volumes.removeValue(forKey: path)
        emit(.volumeUnmounted(uuid: uuid))
    }

    func powerChanged() {
        guard !closed else { return }
        let observation = LocalPowerStateSampler.read()
        if observation != lastPower {
            lastPower = observation
            emit(.power(observation))
        }
    }

    private func emit(_ event: SystemEvent) {
        guard !closed else { return }
        if case .dropped = continuation.yield(event) {
            // Losing a wake or mount edge must be visible to the owner, never silently ignored.
            continuation.finish(throwing: SystemMonitoringError.unavailable)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let id = callbackID {
            SystemEventCallbackRegistry.remove(id)
            callbackID = nil
            let context = UnsafeMutableRawPointer(bitPattern: id)
            if let diskSession {
                DAUnregisterCallback(
                    diskSession, unsafeBitCast(systemDiskAppeared, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(
                    diskSession, unsafeBitCast(systemDiskChanged, to: UnsafeMutableRawPointer.self), context)
                DAUnregisterCallback(
                    diskSession, unsafeBitCast(systemDiskDisappeared, to: UnsafeMutableRawPointer.self), context)
            }
        }
        if let diskSession { DASessionSetDispatchQueue(diskSession, nil) }
        diskSession = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        volumes.removeAll()
        diskMounts.removeAll()
        continuation.finish()
    }

    isolated deinit { close() }
}

// The borrowed C disk never crosses actors. Only its address is captured by assumeIsolated.
private func systemDiskEvent(_ disk: DADisk, _ context: UnsafeMutableRawPointer?, disappeared: Bool = false) {
    guard let context else { return }
    let id = UInt(bitPattern: context)
    let address = UInt(bitPattern: Unmanaged.passUnretained(disk).toOpaque())
    MainActor.assumeIsolated {
        guard let owner = SystemEventCallbackRegistry.session(for: id),
            let pointer = UnsafeMutableRawPointer(bitPattern: address)
        else { return }
        owner.diskChanged(Unmanaged<DADisk>.fromOpaque(pointer).takeUnretainedValue(), disappeared: disappeared)
    }
}

let systemPowerChanged: IOPowerSourceCallbackType = { context in
    guard let context else { return }
    let id = UInt(bitPattern: context)
    MainActor.assumeIsolated { SystemEventCallbackRegistry.session(for: id)?.powerChanged() }
}
private let systemDiskAppeared: DADiskAppearedCallback = { disk, context in systemDiskEvent(disk, context) }
private let systemDiskChanged: DADiskDescriptionChangedCallback = { disk, _, context in systemDiskEvent(disk, context) }
private let systemDiskDisappeared: DADiskDisappearedCallback = { disk, context in
    systemDiskEvent(disk, context, disappeared: true)
}
