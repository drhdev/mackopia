import Foundation

public struct HealthThresholds: Codable, Sendable, Hashable {
    public let warnAfter: Duration
    public let criticalAfter: Duration

    public init(warnAfter: Duration = .seconds(259_200), criticalAfter: Duration = .seconds(604_800)) throws {
        guard warnAfter > .zero, criticalAfter > warnAfter else { throw DomainValidationError.invalidPlan }
        self.warnAfter = warnAfter
        self.criticalAfter = criticalAfter
    }

    private enum CodingKeys: String, CodingKey { case warnAfter, criticalAfter }
    private struct Interval: Codable {
        let seconds: Int64
        let attoseconds: Int64

        init(_ duration: Duration) {
            (seconds, attoseconds) = duration.components
        }

        func duration() throws -> Duration {
            guard seconds >= 0, (0..<1_000_000_000_000_000_000).contains(attoseconds) else {
                throw DomainValidationError.invalidPlan
            }
            return Duration(secondsComponent: seconds, attosecondsComponent: attoseconds)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            warnAfter: c.decode(Interval.self, forKey: .warnAfter).duration(),
            criticalAfter: c.decode(Interval.self, forKey: .criticalAfter).duration())
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Interval(warnAfter), forKey: .warnAfter)
        try c.encode(Interval(criticalAfter), forKey: .criticalAfter)
    }
}
