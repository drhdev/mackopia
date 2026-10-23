import Foundation

package enum SecretStoreError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidConfiguration, invalidValue, unavailable, accessDenied, unexpectedResult

    package var errorDescription: String? {
        switch self {
        case .invalidValue: String(localized: "Die Zugangsdaten konnten nicht gespeichert werden.")
        case .accessDenied: String(localized: "Der Zugriff auf den Schlüsselbund wurde abgelehnt.")
        default: String(localized: "Der Schlüsselbund ist nicht verfügbar.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .invalidConfiguration: "Missing or invalid Keychain team identity"
        case .invalidValue: "Invalid bounded secret payload"
        case .unavailable: "Data Protection Keychain is unavailable"
        case .accessDenied: "Keychain access was denied"
        case .unexpectedResult: "Unexpected Keychain result"
        }
    }
}
