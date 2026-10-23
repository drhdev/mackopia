import DiskArbitration
import Foundation

/// DiskArbitration callbacks and teardown run serially on the main queue. Only value events cross actors.
@MainActor
final class DiskVolumeProtectionSession: VolumeProtectionSession {
    nonisolated let events: AsyncStream<VolumeProtectionEvent>
    private let continuation: AsyncStream<VolumeProtectionEvent>.Continuation
    private var callbackID: UInt?
    private var session: DASession?
    private var disks: [DADisk] = []
    private var mountPaths: [String] = []
    private var volumeUUIDs: [String] = []
    private var disappeared = false

    init(volumes: [ResolvedProtectedVolume]) throws {
        let stream = AsyncStream<VolumeProtectionEvent>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream
        continuation = stream.continuation
        guard !volumes.isEmpty, volumes.count <= 1025, let session = DASessionCreate(nil) else {
            throw VolumeProtectionError.unavailable
        }
        self.session = session
        do {
            for volume in volumes {
                try Task.checkCancellation()
                guard let disk = volume.device.withCString({ DADiskCreateFromBSDName(nil, session, $0) }),
                    let description = DADiskCopyDescription(disk) as? [String: Any],
                    Self.uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]) == volume.uuid,
                    let mounted = description[kDADiskDescriptionVolumePathKey as String] as? URL,
                    mounted.standardizedFileURL.path == volume.mountPath
                else { throw VolumeProtectionError.unavailable }
                if !disks.contains(where: { CFEqual($0, disk) }) {
                    disks.append(disk)
                    mountPaths.append(mounted.standardizedFileURL.path)
                    volumeUUIDs.append(volume.uuid)
                }
            }
            let id = try VolumeProtectionCallbackRegistry.insert(self)
            callbackID = id
            let context = UnsafeMutableRawPointer(bitPattern: id)
            DARegisterDiskUnmountApprovalCallback(session, nil, volumeUnmountApproval, context)
            DARegisterDiskDisappearedCallback(session, nil, volumeDisappeared, context)
            DARegisterDiskDescriptionChangedCallback(
                session, nil, [kDADiskDescriptionVolumePathKey, kDADiskDescriptionVolumeUUIDKey] as CFArray,
                volumeDescriptionChanged, context)
            // DiskArbitration requires a dispatch queue; mutable callback state stays MainActor-isolated.
            DASessionSetDispatchQueue(session, .main)
        } catch {
            closeNow()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw VolumeProtectionError.unavailable
        }
    }

    nonisolated static func uuidString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let object = value as AnyObject
        guard CFGetTypeID(object) == CFUUIDGetTypeID() else { return nil }
        // CF's runtime type check above proves this reference is a CFUUID; Swift cannot conditionally cast it.
        let uuid = unsafeDowncast(object, to: CFUUID.self)
        return CFUUIDCreateString(nil, uuid) as String
    }

    func checkActive() async throws {
        try Task.checkCancellation()
        guard session != nil else { throw VolumeProtectionError.unavailable }
        for disk in disks { observeDescription(disk) }
        guard !disappeared else { throw VolumeProtectionError.volumeDisappeared }
    }

    func close() async { closeNow() }

    private func closeNow() {
        guard let session else { return }
        if let id = callbackID {
            // Invalidate the token first: queued callbacks cannot recover a released owner.
            VolumeProtectionCallbackRegistry.remove(id)
            callbackID = nil
            let context = UnsafeMutableRawPointer(bitPattern: id)
            // The C API takes void* for removal; these are the exact registered C function pointers.
            DAUnregisterCallback(
                session, unsafeBitCast(volumeUnmountApproval, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(session, unsafeBitCast(volumeDisappeared, to: UnsafeMutableRawPointer.self), context)
            DAUnregisterCallback(
                session, unsafeBitCast(volumeDescriptionChanged, to: UnsafeMutableRawPointer.self), context)
        }
        DASessionSetDispatchQueue(session, nil)
        self.session = nil
        disks.removeAll()
        mountPaths.removeAll()
        volumeUUIDs.removeAll()
        continuation.finish()
    }

    func blocksUnmount(_ disk: DADisk) -> Bool {
        session != nil && disks.contains { CFEqual($0, disk) }
    }

    func observeDisappearance(_ disk: DADisk) {
        guard blocksUnmount(disk) else { return }
        signalDisappearance()
    }

    func observeDescription(_ disk: DADisk) {
        guard session != nil, let index = disks.firstIndex(where: { CFEqual($0, disk) }) else { return }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let mounted = description?[kDADiskDescriptionVolumePathKey as String] as? URL
        if mounted?.standardizedFileURL.path != mountPaths[index]
            || Self.uuidString(description?[kDADiskDescriptionVolumeUUIDKey as String]) != volumeUUIDs[index]
        {
            signalDisappearance()
        }
    }

    private func signalDisappearance() {
        guard !disappeared else { return }
        disappeared = true
        continuation.yield(.disappeared)
        continuation.finish()
    }

    isolated deinit { closeNow() }
}

/// These callbacks execute synchronously on the main queue. The borrowed disk stays valid until
/// return. Only its address enters assumeIsolated; the owner is resolved from a weak opaque-token registry.
private func withCallbackOwner<Result: Sendable>(
    disk: DADisk, context: UnsafeMutableRawPointer?,
    body: @MainActor (DiskVolumeProtectionSession, DADisk) -> Result
) -> Result? {
    guard let context else { return nil }
    let ownerID = UInt(bitPattern: context)
    let diskAddress = UInt(bitPattern: Unmanaged.passUnretained(disk).toOpaque())
    return MainActor.assumeIsolated {
        guard let owner = VolumeProtectionCallbackRegistry.session(for: ownerID),
            let diskPointer = UnsafeMutableRawPointer(bitPattern: diskAddress)
        else { return nil }
        return body(
            owner,
            Unmanaged<DADisk>.fromOpaque(diskPointer).takeUnretainedValue())
    }
}

let volumeUnmountApproval: DADiskUnmountApprovalCallback = { disk, context in
    let blocked = withCallbackOwner(disk: disk, context: context) { $0.blocksUnmount($1) } ?? false
    guard blocked else { return nil }
    // Keep the non-Sendable CF return value within the synchronous C callback.
    return Unmanaged.passRetained(
        DADissenterCreate(
            nil, DAReturn(kDAReturnBusy), String(localized: "MacKopia sichert gerade auf diesem Laufwerk.") as CFString)
    )
}

let volumeDisappeared: DADiskDisappearedCallback = { disk, context in
    withCallbackOwner(disk: disk, context: context) { $0.observeDisappearance($1) }
}

private let volumeDescriptionChanged: DADiskDescriptionChangedCallback = { disk, _, context in
    withCallbackOwner(disk: disk, context: context) { $0.observeDescription($1) }
}
