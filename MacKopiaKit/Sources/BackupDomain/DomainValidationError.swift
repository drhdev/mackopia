import Foundation

public enum DomainValidationError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidPath, invalidVolumeIdentity, invalidSource, invalidSnapshotIdentity, invalidRepository
    case volumeUnavailable, volumeMismatch
    case invalidPlan, sourceConflict

    public var errorDescription: String? {
        switch self {
        case .volumeUnavailable: String(localized: "Das Laufwerk ist nicht verfügbar.")
        case .volumeMismatch: String(localized: "Das angeschlossene Laufwerk stimmt nicht überein.")
        default: String(localized: "Die Backup-Konfiguration ist ungültig.")
        }
    }

    public var debugDescription: String {
        switch self {
        case .invalidPlan: "Invalid backup plan configuration"
        case .sourceConflict: "Multiple plans address the same destination source"
        case .invalidPath: "Invalid canonical absolute source path"
        case .invalidVolumeIdentity: "Invalid volume identity or remount URL"
        case .invalidSource: "Invalid source bookmark"
        case .invalidSnapshotIdentity: "Invalid snapshot user or host identity"
        case .invalidRepository: "Invalid destination configuration"
        case .volumeUnavailable: "Volume UUID is unavailable"
        case .volumeMismatch: "Observed volume UUID differs from stored identity"
        }
    }
}
