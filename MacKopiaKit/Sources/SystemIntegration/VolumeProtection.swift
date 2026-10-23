import BackupDomain
import Foundation

package struct ProtectedDirectory: Sendable, CustomReflectable {
    package let path: String
    package let volumeUUID: String

    package init(path: String, volumeUUID: String) throws {
        guard DomainValidation.absolutePath(path), let uuid = DomainValidation.volumeUUID(volumeUUID) else {
            throw VolumeProtectionError.unavailable
        }
        self.path = path
        self.volumeUUID = uuid.uuidString
    }

    package var customMirror: Mirror { Mirror(self, children: ["directory": "<private>"]) }
}

package enum VolumeProtectionEvent: Sendable { case disappeared }

package protocol VolumeProtectionSession: Sendable {
    var events: AsyncStream<VolumeProtectionEvent> { get }
    func checkActive() async throws
    func close() async
}

package protocol VolumeProtectionStarting: Sendable {
    func start(directories: [ProtectedDirectory]) async throws -> any VolumeProtectionSession
}

package enum VolumeProtectionError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case unavailable, volumeDisappeared

    package var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Die Laufwerksüberwachung ist nicht verfügbar.")
        case .volumeDisappeared: String(localized: "Ein benötigtes Laufwerk ist nicht mehr verfügbar.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .unavailable: "Volume protection could not be established"
        case .volumeDisappeared: "A protected volume disappeared"
        }
    }
}
