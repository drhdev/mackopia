import Foundation

package enum KopiaBinaryVerificationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidConfiguration, unavailable, probeFailed, invalidResponse, versionMismatch

    package var errorDescription: String? {
        switch self {
        case .versionMismatch: String(localized: "Die Sicherungsfunktion muss aktualisiert werden.")
        default: String(localized: "Die Sicherungsfunktion konnte nicht ausgeführt werden.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .invalidConfiguration: "Invalid isolated binary probe configuration"
        case .unavailable: "Bundled executable is missing, linked or not executable"
        case .probeFailed: "Bounded binary version probe failed"
        case .invalidResponse: "Malformed binary version response"
        case .versionMismatch: "Binary version differs from configured pin"
        }
    }
}
