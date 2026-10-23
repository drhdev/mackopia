import Foundation

struct KopiaSnapshot: Decodable, Sendable, CustomReflectable {
    let id: String?
    let startTime: String?
    let endTime: String?
    let rootID: String?
    let incomplete: String?
    let summary: KopiaDirectorySummary?
    let retention: [String]?
    let pins: [String]?

    var customMirror: Mirror { Mirror(self, children: ["snapshot": "<private>"]) }
}
