import Foundation

package enum JobAdmissionError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case planUnavailable, planDisabled, triggerUnavailable, repositoryUnavailable, configurationChanged

    package var errorDescription: String? {
        switch self {
        case .planUnavailable: String(localized: "Der Backup-Plan ist nicht mehr verfügbar.")
        case .planDisabled: String(localized: "Der Backup-Plan ist deaktiviert.")
        case .triggerUnavailable: String(localized: "Der Auslöser ist nicht mehr eingerichtet.")
        case .repositoryUnavailable: String(localized: "Das Speicherziel ist nicht mehr eingerichtet.")
        case .configurationChanged: String(localized: "Die Backup-Konfiguration hat sich geändert.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .planUnavailable: "Configured plan is unavailable"
        case .planDisabled: "Configured plan is disabled"
        case .triggerUnavailable: "Configured trigger is unavailable"
        case .repositoryUnavailable: "Configured repository is unavailable"
        case .configurationChanged: "Configuration changed during backup preparation"
        }
    }
}
