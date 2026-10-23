import Foundation

enum KopiaServerProcessError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidConfiguration
    case startFailed
    case stopFailed

    var errorDescription: String? { String(localized: "Die Sicherungsfunktion konnte nicht ausgeführt werden.") }
    var debugDescription: String {
        switch self {
        case .invalidConfiguration: "Invalid server configuration"
        case .startFailed: "Server did not become ready"
        case .stopFailed: "Server did not exit successfully"
        }
    }
}
