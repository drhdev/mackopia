import Foundation

package struct KopiaSourceSnapshot: Decodable, Sendable, CustomReflectable {
    package struct Statistics: Decodable, Sendable {
        package let totalSize: Int64?
        package let fileCount: Int64?
        package let cachedFiles: Int64?
        package let errorCount: Int64?
        package let ignoredErrorCount: Int64?
    }

    package let id: String?
    package let startTime: String?
    package let endTime: String?
    package let incomplete: String?
    package let stats: Statistics?

    package var customMirror: Mirror { Mirror(self, children: ["snapshot": "<private>"]) }
}
