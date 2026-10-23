import Foundation

package enum ConfigStoreError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidConfiguration, unsupportedVersion, storageUnavailable, unsafeStorage
    case storageChanged, notLoaded, safeMode, noBackup

    package var errorDescription: String? {
        switch self {
        case .storageUnavailable, .unsafeStorage: String(localized: "Der Ordner ist nicht verfügbar.")
        default: String(localized: "Die Backup-Konfiguration ist ungültig.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .invalidConfiguration: "Invalid configuration document"
        case .unsupportedVersion: "Unsupported configuration schema version"
        case .storageUnavailable: "Configuration storage unavailable"
        case .unsafeStorage: "Unsafe configuration storage attributes"
        case .storageChanged: "Configuration changed outside this session"
        case .notLoaded: "Configuration must be loaded before saving"
        case .safeMode: "Configuration writes blocked in safe mode"
        case .noBackup: "No configuration backup available"
        }
    }
}
