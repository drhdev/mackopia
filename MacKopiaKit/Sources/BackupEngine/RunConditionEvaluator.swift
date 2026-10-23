import BackupDomain

package enum RunConditionResult: Sendable, Equatable {
    case allowed
    case skipped(RunConditionSkipReason)
}

package enum RunConditionSkipReason: Sendable, Equatable {
    case powerStateUnavailable, requiresACPower, lowPowerMode, batteryTooLow
    case networkStateUnavailable, expensiveNetwork, constrainedNetwork, wifiConditionUnavailable
}

/// Evaluate injected observations only; missing information never satisfies an enabled condition.
package enum RunConditionEvaluator {
    package static func evaluate(_ conditions: RunConditions, environment: RunEnvironment) -> RunConditionResult {
        if conditions.requiresACPower {
            guard let ac = environment.isOnACPower, let lowPower = environment.isLowPowerMode else {
                return .skipped(.powerStateUnavailable)
            }
            if !ac { return .skipped(.requiresACPower) }
            if lowPower { return .skipped(.lowPowerMode) }
        }
        if let minimum = conditions.minBatteryPercent {
            guard let hasBattery = environment.hasBattery else { return .skipped(.powerStateUnavailable) }
            if hasBattery {
                guard let percent = environment.batteryPercent else { return .skipped(.powerStateUnavailable) }
                if percent < minimum { return .skipped(.batteryTooLow) }
            }
        }
        if conditions.skipOnExpensiveNetwork {
            guard let expensive = environment.isExpensiveNetwork else { return .skipped(.networkStateUnavailable) }
            if expensive { return .skipped(.expensiveNetwork) }
        }
        if conditions.skipOnConstrainedNetwork {
            guard let constrained = environment.isConstrainedNetwork else { return .skipped(.networkStateUnavailable) }
            if constrained { return .skipped(.constrainedNetwork) }
        }
        // Phase 2: no SSID observer yet. Do not silently disregard an explicitly persisted restriction.
        if conditions.allowedWiFiSSIDs != nil { return .skipped(.wifiConditionUnavailable) }
        return .allowed
    }
}
