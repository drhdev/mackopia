import Foundation

package struct KopiaSourceStatus: Decodable, Sendable, CustomReflectable {
    package struct Source: Decodable, Sendable, CustomReflectable {
        package let host: String?
        package let userName: String?
        package let path: String?

        package var customMirror: Mirror { Mirror(self, children: ["source": "<private>"]) }
    }

    package struct Upload: Decodable, Sendable, CustomReflectable {
        package let cachedBytes: Int64?
        package let hashedBytes: Int64?
        package let uploadedBytes: Int64?
        package let estimatedBytes: Int64?
        package let cachedFiles: Int64?
        package let hashedFiles: Int64?
        package let estimatedFiles: Int64?
        package let excludedFiles: Int64?
        package let excludedDirs: Int64?
        package let errors: Int64?
        package let ignoredErrors: Int64?
        package let directory: String?

        package var customMirror: Mirror { Mirror(self, children: ["upload": "<private>"]) }
    }

    package let source: Source?
    package let status: String?
    package let upload: Upload?
    package let lastSnapshot: KopiaSourceSnapshot?
    package let currentTask: String?

    package var customMirror: Mirror { Mirror(self, children: ["sourceStatus": "<private>"]) }
}
