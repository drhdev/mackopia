import SystemIntegration

/// Fresh live observations; no retained state and no destination connections or SSID queries.
package struct LocalRunEnvironmentSampler: RunEnvironmentSampling {
    private let power: any PowerStateSampling
    private let network: any NetworkPathSampling

    package init(
        power: any PowerStateSampling = LocalPowerStateSampler(),
        network: any NetworkPathSampling = LocalNetworkPathSampler()
    ) {
        self.power = power
        self.network = network
    }

    package func sample() async throws -> RunEnvironment {
        try Task.checkCancellation()
        async let powerObservation = power.samplePower()
        async let networkObservation = network.sampleNetwork()
        let (power, network) = try await (powerObservation, networkObservation)
        try Task.checkCancellation()
        return try RunEnvironment(
            isOnACPower: power.isOnACPower, hasBattery: power.hasBattery, batteryPercent: power.batteryPercent,
            isLowPowerMode: power.isLowPowerMode,
            isExpensiveNetwork: network.isExpensive, isConstrainedNetwork: network.isConstrained)
    }
}
