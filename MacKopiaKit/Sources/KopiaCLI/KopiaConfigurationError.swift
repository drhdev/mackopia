import Foundation

// Internal transport failures carry no payload, path, credentials or underlying error text.
enum KopiaConfigurationError: Error, LocalizedError, CustomDebugStringConvertible {
    case invalidPayload
    case unsafeDirectory
    case transportUnavailable
    case deliveryFailed

    var errorDescription: String? {
        String(localized: "Das Speicherziel konnte nicht sicher geöffnet werden.")
    }

    var debugDescription: String {
        switch self {
        case .invalidPayload: "Invalid runtime configuration payload size"
        case .unsafeDirectory: "Unsafe runtime configuration directory or maintenance lock"
        case .transportUnavailable: "Runtime configuration pipe setup failed"
        case .deliveryFailed: "Runtime configuration pipe delivery failed"
        }
    }
}
