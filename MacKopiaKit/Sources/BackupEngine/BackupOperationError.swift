import Foundation

package enum BackupOperationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case protectionUnavailable, identitiesChanged, operationFailed, volumeDisappeared

    case unsupportedOptions
    case sourceBusy, sourceResponseInvalid, snapshotIncomplete, snapshotMissing, snapshotReferenceMissing,
        sourceStateUnknown

    package var errorDescription: String? {
        switch self {
        case .protectionUnavailable: String(localized: "Die Laufwerksüberwachung ist nicht verfügbar.")
        case .identitiesChanged: String(localized: "Die verfügbaren Quellen haben sich geändert.")
        case .volumeDisappeared: String(localized: "Ein benötigtes Laufwerk ist nicht mehr verfügbar.")
        case .operationFailed, .unsupportedOptions, .sourceBusy, .sourceResponseInvalid, .snapshotIncomplete,
            .snapshotMissing,
            .snapshotReferenceMissing, .sourceStateUnknown:
            String(localized: "Die Sicherung konnte nicht abgeschlossen werden.")
        }
    }

    package var debugDescription: String {
        switch self {
        case .protectionUnavailable: "Live backup volume protection is unavailable"
        case .identitiesChanged: "Source identity observations changed before operation"
        case .volumeDisappeared: "A protected volume disappeared during operation"
        case .unsupportedOptions:
            "Requested advanced run options are not supported by the manual filesystem execution boundary"
        case .sourceBusy: "Source was already active before the requested upload"
        case .sourceResponseInvalid: "Source list or snapshot baseline was invalid"
        case .snapshotIncomplete: "New upload did not yield a complete snapshot with valid statistics"
        case .snapshotReferenceMissing: "Completed source references a snapshot absent from the manifest list"
        case .snapshotMissing: "Source returned idle without a new confirmed snapshot"
        case .sourceStateUnknown: "Source returned an unsupported state"
        case .operationFailed: "Protected backup operation failed"
        }
    }
}
