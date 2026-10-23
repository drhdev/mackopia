import Foundation

public struct RetentionPolicy: Codable, Sendable, Hashable {
    public let keepLatest: Int?
    public let keepHourly: Int?
    public let keepDaily: Int?
    public let keepWeekly: Int?
    public let keepMonthly: Int?
    public let keepAnnual: Int?
    public let preset: RetentionPreset

    public init(
        keepLatest: Int? = nil,
        keepHourly: Int? = nil,
        keepDaily: Int? = nil,
        keepWeekly: Int? = nil,
        keepMonthly: Int? = nil,
        keepAnnual: Int? = nil,
        preset: RetentionPreset = .custom
    ) throws {
        let counts = [keepLatest, keepHourly, keepDaily, keepWeekly, keepMonthly, keepAnnual]
        guard counts.allSatisfy({ $0.map { $0 >= 0 } ?? true }),
            preset.counts.map({ $0 == counts }) ?? true
        else { throw DomainValidationError.invalidPlan }
        self.keepLatest = keepLatest
        self.keepHourly = keepHourly
        self.keepDaily = keepDaily
        self.keepWeekly = keepWeekly
        self.keepMonthly = keepMonthly
        self.keepAnnual = keepAnnual
        self.preset = preset
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            keepLatest: c.decodeIfPresent(Int.self, forKey: .keepLatest),
            keepHourly: c.decodeIfPresent(Int.self, forKey: .keepHourly),
            keepDaily: c.decodeIfPresent(Int.self, forKey: .keepDaily),
            keepWeekly: c.decodeIfPresent(Int.self, forKey: .keepWeekly),
            keepMonthly: c.decodeIfPresent(Int.self, forKey: .keepMonthly),
            keepAnnual: c.decodeIfPresent(Int.self, forKey: .keepAnnual),
            preset: c.decode(RetentionPreset.self, forKey: .preset))
    }

    public init(preset: RetentionPreset) throws {
        guard let counts = preset.counts else { throw DomainValidationError.invalidPlan }
        try self.init(
            keepLatest: counts[0], keepHourly: counts[1], keepDaily: counts[2],
            keepWeekly: counts[3], keepMonthly: counts[4], keepAnnual: counts[5], preset: preset)
    }
}
