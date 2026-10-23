import Foundation

struct KopiaSnapshots: Decodable, Sendable, CustomReflectable {
    let snapshots: [KopiaSnapshot]?
    let unfilteredCount: Int64?
    let uniqueCount: Int64?

    var customMirror: Mirror { Mirror(self, children: ["snapshots": "<private>"]) }
}
