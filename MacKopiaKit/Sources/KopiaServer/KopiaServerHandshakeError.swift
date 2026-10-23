import Foundation

enum KopiaServerHandshakeError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalid
    case limitExceeded
    case incomplete

    var errorDescription: String? { String(localized: "Die Sicherungsfunktion konnte nicht gestartet werden.") }

    var debugDescription: String {
        switch self {
        case .invalid: "Invalid server handshake"
        case .limitExceeded: "Server handshake exceeded its input limit"
        case .incomplete: "Server handshake ended before all fields arrived"
        }
    }
}
