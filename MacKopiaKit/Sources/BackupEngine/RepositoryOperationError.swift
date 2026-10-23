import Foundation

package enum RepositoryOperationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidLimit, repositoryBusy, concurrencyLimitReached

    package var errorDescription: String? {
        switch self {
        case .invalidLimit: String(localized: "Die Backup-Konfiguration ist ungültig.")
        case .repositoryBusy: String(localized: "Das Speicherziel wird gerade verwendet.")
        case .concurrencyLimitReached: String(localized: "Ein anderer Vorgang läuft bereits.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .invalidLimit: "Repository operation limit must be positive"
        case .repositoryBusy: "Repository already has an active operation"
        case .concurrencyLimitReached: "Global repository operation limit reached"
        }
    }
}
