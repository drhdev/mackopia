import Foundation

/// Opaque, never-reused tokens avoid dereferencing released owners from queued C callbacks.
@MainActor
enum SystemEventCallbackRegistry {
    private final class WeakSession {
        weak var value: NativeSystemEventSession?
        init(_ value: NativeSystemEventSession) { self.value = value }
    }
    private static var nextID: UInt = 1
    private static var entries: [UInt: WeakSession] = [:]

    static func insert(_ session: NativeSystemEventSession) throws -> UInt {
        guard nextID < UInt(Int.max) else { throw SystemMonitoringError.unavailable }
        let id = nextID
        nextID += 1
        entries[id] = WeakSession(session)
        return id
    }
    static func session(for id: UInt) -> NativeSystemEventSession? { entries[id]?.value }
    static func remove(_ id: UInt) { entries.removeValue(forKey: id) }
}
