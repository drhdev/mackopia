import BackupDomain
import Foundation

/// Desired plan-owned values, not a complete Kopia policy or a serializable PUT body.
/// The synchronizer preserves unrelated fields and checks Kopia's effective inheritance separately.
package struct TranslatedSourcePolicy: Sendable, Equatable, CustomReflectable {
    package let source: BackupSource
    package let retention: RetentionPolicy
    package let compression: Compression
    package let ignore: [String]
    package let ignoreCacheDirs: Bool
    package let maxFileSize: Int64?
    package let oneFileSystem: Bool

    package var customMirror: Mirror { Mirror(self, children: ["policy": "<private>"]) }
}
