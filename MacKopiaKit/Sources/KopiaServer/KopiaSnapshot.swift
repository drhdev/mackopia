import Foundation

package struct KopiaSnapshot: Decodable, Sendable, CustomReflectable {
    package let id: String?
    package let startTime: String?
    package let endTime: String?
    package let rootID: String?
    package let incomplete: String?
    package let summary: KopiaDirectorySummary?
    package let retention: [String]?
    package let pins: [String]?

    package var customMirror: Mirror { Mirror(self, children: ["snapshot": "<private>"]) }
}
