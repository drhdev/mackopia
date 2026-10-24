import Foundation

/// Absent or invalid wire counters stay unknown; uploads of unchanged data can legitimately remain zero.
public struct BackupProgress: Codable, Sendable, Hashable, CustomReflectable {
    public let planID: UUID
    public let sourceID: UUID
    public let hashedBytes: Int64?
    public let cachedBytes: Int64?
    public let uploadedBytes: Int64?
    public let estimatedBytes: Int64?
    public let hashedFiles: Int64?
    public let cachedFiles: Int64?
    public let estimatedFiles: Int64?
    public let errors: Int64?
    public let ignoredErrors: Int64?
    public let directory: String?

    public var customMirror: Mirror { Mirror(self, children: ["progress": "<private>"]) }

    public let bytesPerSecond: Double?
    public let remainingSeconds: Double?

    public var fractionCompleted: Double? {
        guard let hashedBytes, let cachedBytes, let estimatedBytes, estimatedBytes > 0 else { return nil }
        return min(1, (Double(hashedBytes) + Double(cachedBytes)) / Double(estimatedBytes))
    }

    public init(
        planID: UUID, sourceID: UUID, hashedBytes: Int64?, cachedBytes: Int64?, uploadedBytes: Int64?,
        estimatedBytes: Int64?, hashedFiles: Int64?, cachedFiles: Int64?, estimatedFiles: Int64?,
        errors: Int64?, ignoredErrors: Int64?, bytesPerSecond: Double? = nil, remainingSeconds: Double? = nil,
        directory: String? = nil
    ) {
        func valid(_ value: Int64?) -> Int64? { value.flatMap { $0 >= 0 ? $0 : nil } }
        self.planID = planID
        self.sourceID = sourceID
        self.hashedBytes = valid(hashedBytes)
        self.cachedBytes = valid(cachedBytes)
        self.uploadedBytes = valid(uploadedBytes)
        self.estimatedBytes = valid(estimatedBytes)
        self.hashedFiles = valid(hashedFiles)
        self.cachedFiles = valid(cachedFiles)
        self.estimatedFiles = valid(estimatedFiles)
        self.errors = valid(errors)
        self.ignoredErrors = valid(ignoredErrors)
        self.directory = directory
        self.bytesPerSecond = bytesPerSecond.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.remainingSeconds = remainingSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
}
