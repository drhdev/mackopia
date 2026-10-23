import Foundation

struct KopiaDirectory: Decodable, Sendable, CustomReflectable {
    let stream: String?
    let entries: [KopiaDirectoryEntry]?
    let summary: KopiaDirectorySummary?

    var customMirror: Mirror { Mirror(self, children: ["directory": "<private>"]) }
}
