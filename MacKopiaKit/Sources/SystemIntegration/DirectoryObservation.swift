import BackupDomain
import Foundation

package struct DirectoryObservation: Sendable, Equatable, CustomReflectable {
    package let canonicalPath: String
    package let volumeUUID: String
    package let isCaseSensitive: Bool

    package init(canonicalPath: String, volumeUUID: String, isCaseSensitive: Bool) throws {
        guard DomainValidation.absolutePath(canonicalPath), let uuid = DomainValidation.volumeUUID(volumeUUID) else {
            throw VolumeInspectionError.unavailable
        }
        self.canonicalPath = canonicalPath
        self.volumeUUID = uuid.uuidString
        self.isCaseSensitive = isCaseSensitive
    }

    package var customMirror: Mirror { Mirror(self, children: ["directory": "<private>"]) }
}

package protocol DirectoryInspecting: Sendable {
    func inspectDirectory(at path: String) async throws -> DirectoryObservation
}
