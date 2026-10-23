import Foundation

/// C callbacks carry an opaque integer, never an unretained object pointer. Removing the weak entry
/// makes even a callback queued before teardown harmless. IDs are never reused within this process.
@MainActor
final class VolumeProtectionCallbackRegistry {
    private static var nextID: UInt = 1
    private static var entries: [UInt: WeakSession] = [:]

    static func insert(_ session: DiskVolumeProtectionSession) throws -> UInt {
        guard nextID < UInt(Int.max) else { throw VolumeProtectionError.unavailable }
        let id = nextID
        nextID += 1
        entries[id] = WeakSession(session)
        return id
    }

    static func session(for id: UInt) -> DiskVolumeProtectionSession? { entries[id]?.value }
    static func remove(_ id: UInt) { entries.removeValue(forKey: id) }

    private final class WeakSession {
        weak var value: DiskVolumeProtectionSession?
        init(_ value: DiskVolumeProtectionSession) { self.value = value }
    }
}
