import Foundation

struct KopiaSourceSnapshot: Decodable, Sendable, CustomReflectable {
    struct Statistics: Decodable, Sendable {
        let totalSize: Int64?
        let fileCount: Int64?
        let cachedFiles: Int64?
        let errorCount: Int64?
        let ignoredErrorCount: Int64?
    }

    let id: String?
    let startTime: String?
    let endTime: String?
    let incomplete: String?
    let stats: Statistics?

    var customMirror: Mirror { Mirror(self, children: ["snapshot": "<private>"]) }
}
