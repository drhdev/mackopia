import Foundation

package enum SourcePathStatus: Sendable, Equatable {
    case ready(sourceID: UUID)
    case skipped(sourceID: UUID, reason: SourcePathSkipReason)
}

package enum SourcePathSkipReason: Sendable, Equatable { case unavailable, volumeMismatch, permissionDenied }
