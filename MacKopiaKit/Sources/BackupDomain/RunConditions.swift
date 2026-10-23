import Foundation

public struct RunConditions: Codable, Sendable, Hashable, CustomReflectable {
    public let requiresACPower: Bool
    public let minBatteryPercent: Int?
    public let skipOnExpensiveNetwork: Bool
    public let skipOnConstrainedNetwork: Bool
    public let allowedWiFiSSIDs: [String]?
    public let catchUpMissedRuns: Bool

    public init(
        requiresACPower: Bool,
        minBatteryPercent: Int? = nil,
        skipOnExpensiveNetwork: Bool,
        skipOnConstrainedNetwork: Bool,
        allowedWiFiSSIDs: [String]? = nil,
        catchUpMissedRuns: Bool = true
    ) throws {
        guard minBatteryPercent.map({ (0...100).contains($0) }) ?? true,
            allowedWiFiSSIDs.map({
                !$0.isEmpty && $0.count <= 256
                    && $0.allSatisfy {
                        DomainValidation.text($0, limit: 32)
                    } && Set($0).count == $0.count
            }) ?? true
        else { throw DomainValidationError.invalidPlan }
        self.requiresACPower = requiresACPower
        self.minBatteryPercent = minBatteryPercent
        self.skipOnExpensiveNetwork = skipOnExpensiveNetwork
        self.skipOnConstrainedNetwork = skipOnConstrainedNetwork
        self.allowedWiFiSSIDs = allowedWiFiSSIDs
        self.catchUpMissedRuns = catchUpMissedRuns
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requiresACPower: c.decode(Bool.self, forKey: .requiresACPower),
            minBatteryPercent: c.decodeIfPresent(Int.self, forKey: .minBatteryPercent),
            skipOnExpensiveNetwork: c.decode(Bool.self, forKey: .skipOnExpensiveNetwork),
            skipOnConstrainedNetwork: c.decode(Bool.self, forKey: .skipOnConstrainedNetwork),
            allowedWiFiSSIDs: c.decodeIfPresent([String].self, forKey: .allowedWiFiSSIDs),
            catchUpMissedRuns: c.decode(Bool.self, forKey: .catchUpMissedRuns))
    }

    public var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }
}
