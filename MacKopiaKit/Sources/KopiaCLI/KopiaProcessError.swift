import Foundation

enum KopiaProcessError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case commandFailed(exitCode: Int32)
    case invalidRequest
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case ioFailed
    case waitFailed

    var errorDescription: String? {
        switch self {
        case .timedOut: String(localized: "Das Speicherziel antwortet nicht rechtzeitig.")
        default: String(localized: "Die Sicherungsfunktion konnte nicht ausgeführt werden.")
        }
    }

    var debugDescription: String {
        switch self {
        case .commandFailed(let code): "Kopia command failed with exit code \(code)"
        case .invalidRequest: "Invalid child process request"
        case .launchFailed: "Child process launch failed"
        case .timedOut: "Child process deadline exceeded"
        case .outputLimitExceeded: "Child process output exceeded its capture limit"
        case .ioFailed: "Child process pipe failed"
        case .waitFailed: "Child process reaping failed"
        }
    }
}
