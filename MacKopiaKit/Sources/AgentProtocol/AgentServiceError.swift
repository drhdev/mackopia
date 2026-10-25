import Foundation

public enum AgentServiceError: Error, LocalizedError, CustomDebugStringConvertible, Sendable {
    case invalidIdentity
    case signingRequired
    case unavailable
    case timedOut
    case incompatibleProtocol
    case invalidReply
    case registrationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity, .signingRequired:
            String(localized: "Für den Hintergrunddienst ist eine gültige App-Signatur erforderlich.")
        case .unavailable, .registrationFailed:
            String(localized: "Der Hintergrunddienst ist nicht verfügbar.")
        case .timedOut:
            String(localized: "Der Hintergrunddienst antwortet nicht.")
        case .incompatibleProtocol:
            String(localized: "Starte MacKopia und den Hintergrunddienst neu, um die Versionen abzugleichen.")
        case .invalidReply:
            String(localized: "Die Antwort des Hintergrunddienstes konnte nicht geprüft werden.")
        }
    }

    public var debugDescription: String {
        switch self {
        case .invalidIdentity: "Invalid application bundle identifier"
        case .signingRequired: "Valid bundle signature and pinned peer code identity required"
        case .unavailable: "XPC service unavailable"
        case .timedOut: "XPC ping deadline exceeded"
        case .incompatibleProtocol: "Agent protocol version mismatch"
        case .invalidReply: "XPC reply correlation failed"
        case .registrationFailed: "SMAppService registration failed"
        }
    }
}
