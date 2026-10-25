import BackupDomain
import DiskArbitration
import Foundation

/// Default DiskArbitration options preserve other applications' unmount vetoes. Never force.
package struct LocalVolumeEjector: Sendable {
    package init() {}

    package static func mountPoint(path: String, volume: VolumeIdentity) throws -> URL {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeURLKey])
        try volume.requireMatch(uuid: values.volumeUUIDString)
        guard values.isDirectory == true, let mountPoint = values.volume else {
            throw DomainValidationError.volumeUnavailable
        }
        // DADiskCreateFromVolumePath requires the BSD mount point, not a directory inside it.
        return mountPoint
    }

    package func eject(path: String, volume: VolumeIdentity) async throws {
        try Task.checkCancellation()
        try await EjectionSession.perform(path: path, volume: volume)
    }
}

@MainActor
private final class EjectionSession {
    private static var nextID: UInt = 0
    private static var sessions: [UInt: EjectionSession] = [:]
    private let session: DASession
    private let disk: DADisk
    private var completion: CheckedContinuation<Void, any Error>?
    private var id: UInt = 0

    private init(path: String, volume: VolumeIdentity) throws {
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsRemovableKey, .volumeIsLocalKey])
        try volume.requireMatch(uuid: values.volumeUUIDString)
        guard volume.isRemovable, !volume.isNetwork, values.volumeIsRemovable == true,
            values.volumeIsLocal == true, let session = DASessionCreate(nil),
            let disk = DADiskCreateFromVolumePath(
                nil, session, try LocalVolumeEjector.mountPoint(path: path, volume: volume) as CFURL),
            let description = DADiskCopyDescription(disk) as? [String: Any],
            let uuid = DiskVolumeProtectionSession.uuidString(description[kDADiskDescriptionVolumeUUIDKey as String]),
            uuid == volume.uuid
        else { throw DomainValidationError.volumeUnavailable }
        self.session = session; self.disk = disk
    }

    static func perform(path: String, volume: VolumeIdentity) async throws {
        let operation = try EjectionSession(path: path, volume: volume)
        try Task.checkCancellation()
        // Join the native callback even on cancellation. Releasing the owner's gate early could
        // admit a write while an already accepted unmount is still in flight.
        try await withCheckedThrowingContinuation { continuation in
            nextID += 1
            operation.id = nextID
            sessions[nextID] = operation
            operation.completion = continuation
            DASessionSetDispatchQueue(operation.session, .main)
            DADiskUnmount(
                operation.disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), unmounted,
                UnsafeMutableRawPointer(bitPattern: nextID))
        }
        try Task.checkCancellation()
    }

    private static let unmounted: DADiskUnmountCallback = { _, dissenter, context in
        let id = UInt(bitPattern: context)
        let succeeded = dissenter == nil
        MainActor.assumeIsolated {
            guard let operation = sessions[id] else { return }
            if succeeded {
                DADiskEject(
                    operation.disk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejected,
                    UnsafeMutableRawPointer(bitPattern: id))
            } else {
                operation.finish(succeeded: false)
            }
        }
    }

    private static let ejected: DADiskEjectCallback = { _, dissenter, context in
        let id = UInt(bitPattern: context)
        let succeeded = dissenter == nil
        MainActor.assumeIsolated { sessions[id]?.finish(succeeded: succeeded) }
    }

    private func finish(succeeded: Bool) {
        DASessionSetDispatchQueue(session, nil)
        Self.sessions.removeValue(forKey: id)
        let continuation = completion
        completion = nil
        if succeeded {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: DomainValidationError.volumeUnavailable)
        }
    }
}
