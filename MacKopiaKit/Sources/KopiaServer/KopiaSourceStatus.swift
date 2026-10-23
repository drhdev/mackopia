import Foundation

struct KopiaSourceStatus: Decodable, Sendable, CustomReflectable {
    struct Source: Decodable, Sendable, CustomReflectable {
        let host: String?
        let userName: String?
        let path: String?

        var customMirror: Mirror { Mirror(self, children: ["source": "<private>"]) }
    }

    struct Upload: Decodable, Sendable {
        let cachedBytes: Int64?
        let hashedBytes: Int64?
        let uploadedBytes: Int64?
        let estimatedBytes: Int64?
        let cachedFiles: Int64?
        let hashedFiles: Int64?
        let estimatedFiles: Int64?
        let excludedFiles: Int64?
        let excludedDirs: Int64?
        let errors: Int64?
        let ignoredErrors: Int64?
    }

    let source: Source?
    let status: String?
    let upload: Upload?
    let lastSnapshot: KopiaSourceSnapshot?
    let currentTask: String?

    var customMirror: Mirror { Mirror(self, children: ["sourceStatus": "<private>"]) }
}
