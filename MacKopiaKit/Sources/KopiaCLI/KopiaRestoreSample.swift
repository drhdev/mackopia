import Foundation

/// Private snapshot metadata is kept in memory and never used as an output pathname.
package struct KopiaRestoreSample: Sendable, CustomReflectable {
    package let components: [String]
    package let objectID: String
    package let size: Int64
    package let modifiedAt: Date
    package var customMirror: Mirror { Mirror(self, children: ["sample": "<private>"]) }
}
