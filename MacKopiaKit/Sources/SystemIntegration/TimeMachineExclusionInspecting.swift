import Foundation

/// Missing exclusion metadata must throw rather than imply that a path is included.
package protocol TimeMachineExclusionInspecting: Sendable {
    func inspect(_ path: String) async throws -> TimeMachineExclusionEntry
    func children(of path: String, limit: Int) async throws -> [String]
}

package struct TimeMachineExclusionEntry: Sendable, CustomReflectable {
    package var customMirror: Mirror { Mirror(self, children: ["entry": "<private>"]) }

    package let volumeUUID: String
    package let isDirectory: Bool
    package let isSymbolicLink: Bool
    package let isExcluded: Bool

    package init(volumeUUID: String, isDirectory: Bool, isSymbolicLink: Bool, isExcluded: Bool) {
        self.volumeUUID = volumeUUID
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.isExcluded = isExcluded
    }
}

package enum TimeMachineExclusionError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case unavailable, limitExceeded, invalidSource, staleResult

    package var errorDescription: String? { String(localized: "Der Ordner ist nicht verfügbar.") }

    package var debugDescription: String {
        switch self {
        case .unavailable: "Time Machine exclusion metadata is unavailable"
        case .limitExceeded: "Time Machine exclusion scan exceeded its time or entry budget"
        case .invalidSource: "Time Machine exclusion source identity or path does not match"
        case .staleResult: "Time Machine exclusion result is stale or belongs to another source"
        }
    }
}
