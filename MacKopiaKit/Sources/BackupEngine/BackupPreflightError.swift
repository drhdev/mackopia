import Foundation

package enum BackupPreflightError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case repositoryMismatch, overlappingSources, sourceDestinationOverlap, unboundDestination
    case destinationUnavailable, destinationVolumeMismatch, destinationPermissionDenied, invalidEnvironment
    case backupPasswordRequired

    package var errorDescription: String? {
        switch self {
        case .destinationUnavailable: String(localized: "Der Ordner ist nicht verfügbar.")
        case .destinationVolumeMismatch: String(localized: "Das angeschlossene Laufwerk stimmt nicht überein.")
        case .destinationPermissionDenied: String(localized: "Der Zugriff auf den Ordner wurde abgelehnt.")
        case .backupPasswordRequired: String(localized: "Gib dein Backup-Passwort ein.")
        default: String(localized: "Die Backup-Konfiguration ist ungültig.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .repositoryMismatch: "Plan destination identity differs from supplied destination"
        case .overlappingSources: "Plan source directories overlap"
        case .sourceDestinationOverlap: "Source and destination directories overlap"
        case .unboundDestination: "Filesystem destination has no bound volume identity"
        case .destinationUnavailable: "Destination directory could not be inspected"
        case .destinationVolumeMismatch: "Destination volume identity mismatch"
        case .destinationPermissionDenied: "Destination metadata access denied"
        case .invalidEnvironment: "Invalid sampled run environment"
        case .backupPasswordRequired: "Backup password reference is missing from Keychain"
        }
    }
}
