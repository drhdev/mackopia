import Foundation

enum KopiaServerClientError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidRequest
    case transport
    case response
    case responseTooLarge
    case authentication
    case csrf
    case closed
    case policyNotFound

    var errorDescription: String? { String(localized: "Die Sicherungsfunktion konnte nicht ausgeführt werden.") }
    var debugDescription: String {
        switch self {
        case .invalidRequest: "Invalid local server request"
        case .transport: "Pinned server connection failed"
        case .response: "Unexpected server response"
        case .responseTooLarge: "Server response exceeded its input limit"
        case .authentication: "Server authentication failed"
        case .csrf: "Invalid ephemeral server session"
        case .closed: "Server client is closed"
        case .policyNotFound: "No policy is defined for this source"
        }
    }
}
