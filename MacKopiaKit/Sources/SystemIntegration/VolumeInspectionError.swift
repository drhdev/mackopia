import Foundation

package enum VolumeInspectionError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidPath, notDirectory, unavailable, permissionDenied

    package var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Der Zugriff auf den Ordner wurde abgelehnt.")
        default: String(localized: "Der Ordner ist nicht verfügbar.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .invalidPath: "Invalid directory path for volume inspection"
        case .notDirectory: "Volume inspection requires an existing directory"
        case .unavailable: "Current volume identity could not be determined"
        case .permissionDenied: "Directory metadata access was denied"
        }
    }
}
