import Foundation

package struct KopiaDirectory: Decodable, Sendable, CustomReflectable {
    package let stream: String?
    package let entries: [KopiaDirectoryEntry]?
    package let summary: KopiaDirectorySummary?

    package var customMirror: Mirror { Mirror(self, children: ["directory": "<private>"]) }
}
