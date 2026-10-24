import Foundation

package struct KopiaSnapshots: Decodable, Sendable, CustomReflectable {
    package let snapshots: [KopiaSnapshot]?
    package let unfilteredCount: Int64?
    package let uniqueCount: Int64?

    package var customMirror: Mirror { Mirror(self, children: ["snapshots": "<private>"]) }
}
