import Foundation

public struct PlanOptions: Codable, Sendable, Hashable {
    public let compression: Compression
    public let parallelism: Int?
    public let lowPriority: Bool
    public let uploadLimitMbps: Double?
    public let ejectVolumeAfterBackup: Bool
    public let plausibilityDropPercent: Int

    public init(
        compression: Compression = .zstd,
        parallelism: Int? = nil,
        lowPriority: Bool,
        uploadLimitMbps: Double? = nil,
        ejectVolumeAfterBackup: Bool,
        plausibilityDropPercent: Int = 50
    ) throws {
        // Double rounds Int64.max up; exclude that boundary before any later bytes-per-second conversion.
        guard (1...100).contains(plausibilityDropPercent),
            parallelism.map({ $0 > 0 && $0 <= Int(Int32.max) }) ?? true,
            uploadLimitMbps.map({ $0.isFinite && $0 > 0 && $0 < Double(Int64.max) / 125_000 }) ?? true
        else { throw DomainValidationError.invalidPlan }
        self.compression = compression
        self.parallelism = parallelism
        self.lowPriority = lowPriority
        self.uploadLimitMbps = uploadLimitMbps
        self.ejectVolumeAfterBackup = ejectVolumeAfterBackup
        self.plausibilityDropPercent = plausibilityDropPercent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            compression: c.decode(Compression.self, forKey: .compression),
            parallelism: c.decodeIfPresent(Int.self, forKey: .parallelism),
            lowPriority: c.decode(Bool.self, forKey: .lowPriority),
            uploadLimitMbps: c.decodeIfPresent(Double.self, forKey: .uploadLimitMbps),
            ejectVolumeAfterBackup: c.decode(Bool.self, forKey: .ejectVolumeAfterBackup),
            plausibilityDropPercent: c.decodeIfPresent(Int.self, forKey: .plausibilityDropPercent) ?? 50)
    }
}
