package struct RunEnvironment: Sendable, Equatable {
    package let isOnACPower: Bool?
    package let hasBattery: Bool?
    package let batteryPercent: Int?
    package let isLowPowerMode: Bool?
    package let isExpensiveNetwork: Bool?
    package let isConstrainedNetwork: Bool?

    package init(
        isOnACPower: Bool? = nil, hasBattery: Bool? = nil, batteryPercent: Int? = nil,
        isLowPowerMode: Bool? = nil, isExpensiveNetwork: Bool? = nil, isConstrainedNetwork: Bool? = nil
    ) throws {
        guard batteryPercent.map({ (0...100).contains($0) }) ?? true,
            hasBattery != false || batteryPercent == nil
        else { throw BackupPreflightError.invalidEnvironment }
        self.isOnACPower = isOnACPower
        self.hasBattery = hasBattery
        self.batteryPercent = batteryPercent
        self.isLowPowerMode = isLowPowerMode
        self.isExpensiveNetwork = isExpensiveNetwork
        self.isConstrainedNetwork = isConstrainedNetwork
    }
}
