import Foundation

package enum KopiaPolicyMergeError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case invalidDocument

    package var errorDescription: String? { String(localized: "Die Backup-Konfiguration ist ungültig.") }
    package var debugDescription: String { "Invalid or oversized complete Kopia policy document" }
}
