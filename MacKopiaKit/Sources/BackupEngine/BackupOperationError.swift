import Foundation

package enum BackupOperationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case protectionUnavailable, identitiesChanged, operationFailed, volumeDisappeared

    package var errorDescription: String? {
        switch self {
        case .protectionUnavailable: String(localized: "Die Laufwerksüberwachung ist nicht verfügbar.")
        case .identitiesChanged: String(localized: "Die verfügbaren Quellen haben sich geändert.")
        case .volumeDisappeared: String(localized: "Ein benötigtes Laufwerk ist nicht mehr verfügbar.")
        case .operationFailed: String(localized: "Die Sicherung konnte nicht abgeschlossen werden.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .protectionUnavailable: "Live backup volume protection is unavailable"
        case .identitiesChanged: "Source identity observations changed before operation"
        case .volumeDisappeared: "A protected volume disappeared during operation"
        case .operationFailed: "Protected backup operation failed"
        }
    }
}
