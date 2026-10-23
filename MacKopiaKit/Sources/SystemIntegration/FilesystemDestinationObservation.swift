import BackupDomain
import Foundation

/// Metadata only; writability is a point-in-time OS observation, not a successful repository write.
package struct FilesystemDestinationObservation: Sendable, Equatable, CustomReflectable {
    package let volumeUUID: String
    package let isWritable: Bool
    package let availableBytes: Int64
    package let totalBytes: Int64

    package init(volumeUUID: String, isWritable: Bool, availableBytes: Int64, totalBytes: Int64) throws {
        guard let uuid = DomainValidation.volumeUUID(volumeUUID), availableBytes >= 0, totalBytes > 0 else {
            throw VolumeInspectionError.unavailable
        }
        self.volumeUUID = uuid.uuidString
        self.isWritable = isWritable
        self.availableBytes = availableBytes
        self.totalBytes = totalBytes
    }

    package var customMirror: Mirror { Mirror(self, children: ["metadata": "<private>"]) }
}

package protocol FilesystemDestinationInspecting: Sendable {
    func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation
}
