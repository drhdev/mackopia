package struct PowerStateObservation: Sendable, Equatable {
    package let isOnACPower: Bool?
    package let hasBattery: Bool?
    package let batteryPercent: Int?
    package let isLowPowerMode: Bool

    init(onACPower: Bool?, sources: [PowerSourceReading]?, lowPowerMode: Bool) {
        isOnACPower = onACPower
        isLowPowerMode = lowPowerMode
        guard let sources else {
            hasBattery = nil
            batteryPercent = nil
            return
        }
        let batteries = sources.filter { $0.kind == .internalBattery }
        if batteries.isEmpty {
            // A missing/unknown source description cannot prove this is a desktop without a battery.
            hasBattery = sources.contains { $0.kind == .unknown } ? nil : false
            batteryPercent = nil
        } else {
            hasBattery = true
            let percentages = batteries.compactMap(\.percent)
            // Conservatively require every internal battery to meet the requested minimum.
            batteryPercent =
                percentages.count == batteries.count && !sources.contains { $0.kind == .unknown }
                ? percentages.min() : nil
        }
    }
}

struct PowerSourceReading: Sendable {
    enum Kind { case internalBattery, ups, unknown }
    let kind: Kind
    let current: Int?
    let maximum: Int?
    let isPresent: Bool?

    var percent: Int? {
        guard isPresent == true, let current, let maximum,
            maximum > 0, current >= 0, current <= maximum
        else { return nil }
        let scaled = current.multipliedReportingOverflow(by: 100)
        guard !scaled.overflow else { return nil }
        return scaled.partialValue / maximum
    }
}

package protocol PowerStateSampling: Sendable {
    func samplePower() async throws -> PowerStateObservation
}
