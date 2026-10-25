import Foundation

package struct KopiaTask: Decodable, Sendable, CustomReflectable {
    package struct Counter: Decodable, Sendable {
        package let value: Int64?
        package let units: String?
        package let level: String?
    }

    package let id: String?
    package let startTime: String?
    package let endTime: String?
    package let kind: String?
    package let status: String?
    package let counters: [String: Counter]?

    // Raw descriptions, progressInfo and error text are deliberately not part of this boundary.
    package var customMirror: Mirror { Mirror(self, children: ["task": "<private>"]) }
}
