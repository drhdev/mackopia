import Foundation

struct KopiaTask: Decodable, Sendable, CustomReflectable {
    struct Counter: Decodable, Sendable {
        let value: Int64?
        let units: String?
        let level: String?
    }

    let id: String?
    let startTime: String?
    let endTime: String?
    let kind: String?
    let status: String?
    let counters: [String: Counter]?

    // Raw descriptions, progressInfo and error text are deliberately not part of this boundary.
    var customMirror: Mirror { Mirror(self, children: ["task": "<private>"]) }
}
