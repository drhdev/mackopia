import Foundation

package enum PolicySynchronizationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case busy, conflict, effectiveMismatch, schedulingEnabled, verificationFailed

    package var errorDescription: String? { String(localized: "Die Backup-Konfiguration ist ungültig.") }
    package var debugDescription: String {
        switch self {
        case .busy: "Policy synchronization is already active"
        case .conflict: "Policy changed during synchronization"
        case .effectiveMismatch: "Effective policy does not match the backup plan"
        case .schedulingEnabled: "Kopia scheduling must be disabled before synchronization"
        case .verificationFailed: "Policy write outcome could not be verified; reread before retrying"
        }
    }
}
