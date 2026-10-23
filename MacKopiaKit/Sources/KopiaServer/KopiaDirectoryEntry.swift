import Foundation

/// Names are untrusted display data, never local output paths. Restore validation belongs to the engine.
struct KopiaDirectoryEntry: Decodable, Sendable, CustomReflectable {
    let name: String?
    let type: String?
    let mode: String?
    let size: Int64?
    let mtime: String?
    let obj: String?
    let summ: KopiaDirectorySummary?

    var customMirror: Mirror { Mirror(self, children: ["entry": "<private>"]) }
}
