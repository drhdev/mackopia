import Foundation

/// Names are untrusted display data, never local output paths. Restore validation belongs to the engine.
package struct KopiaDirectoryEntry: Decodable, Sendable, CustomReflectable {
    package let name: String?
    package let type: String?
    package let mode: String?
    package let size: Int64?
    package let mtime: String?
    package let obj: String?
    package let summ: KopiaDirectorySummary?

    package var customMirror: Mirror { Mirror(self, children: ["entry": "<private>"]) }
}
