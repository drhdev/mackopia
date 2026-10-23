import BackupDomain
import BackupEngine
import Testing

struct RunConditionTests {
    @Test func disabledRestrictionsNeedNoObservationsAndCatchUpIsNotAnAdmissionRule() throws {
        for catchUp in [false, true] {
            let conditions = try RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false,
                skipOnConstrainedNetwork: false, catchUpMissedRuns: catchUp)
            #expect(RunConditionEvaluator.evaluate(conditions, environment: try RunEnvironment()) == .allowed)
        }
    }

    @Test func acRequirementNeedsKnownPowerAndRejectsLowPowerModeEvenOnAC() throws {
        let conditions = try RunConditions(
            requiresACPower: true, skipOnExpensiveNetwork: false,
            skipOnConstrainedNetwork: false)
        for (environment, result) in [
            (try RunEnvironment(), RunConditionResult.skipped(.powerStateUnavailable)),
            (try RunEnvironment(isOnACPower: true), .skipped(.powerStateUnavailable)),
            (try RunEnvironment(isOnACPower: false, isLowPowerMode: false), .skipped(.requiresACPower)),
            (try RunEnvironment(isOnACPower: true, isLowPowerMode: true), .skipped(.lowPowerMode)),
            (try RunEnvironment(isOnACPower: true, isLowPowerMode: false), .allowed),
        ] { #expect(RunConditionEvaluator.evaluate(conditions, environment: environment) == result) }
    }

    @Test func minimumBatteryIncludesThresholdAndDoesNotRequireBatteryOnDesktop() throws {
        let conditions = try RunConditions(
            requiresACPower: false, minBatteryPercent: 50,
            skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false)
        for (environment, result) in [
            (try RunEnvironment(), RunConditionResult.skipped(.powerStateUnavailable)),
            (try RunEnvironment(hasBattery: true), .skipped(.powerStateUnavailable)),
            (try RunEnvironment(hasBattery: true, batteryPercent: 49), .skipped(.batteryTooLow)),
            (try RunEnvironment(hasBattery: true, batteryPercent: 50), .allowed),
            (try RunEnvironment(hasBattery: true, batteryPercent: 100), .allowed),
            (try RunEnvironment(hasBattery: false), .allowed),
            (try RunEnvironment(isOnACPower: true, hasBattery: true, batteryPercent: 1), .skipped(.batteryTooLow)),
        ] { #expect(RunConditionEvaluator.evaluate(conditions, environment: environment) == result) }
        #expect(throws: BackupPreflightError.invalidEnvironment) { try RunEnvironment(batteryPercent: -1) }
        #expect(throws: BackupPreflightError.invalidEnvironment) { try RunEnvironment(batteryPercent: 101) }
        #expect(throws: BackupPreflightError.invalidEnvironment) {
            try RunEnvironment(hasBattery: false, batteryPercent: 50)
        }
    }

    @Test func networkRestrictionsAreIndependentAndUnknownValuesDoNotSatisfyThem() throws {
        for (expensive, constrained) in [(true, false), (false, true), (true, true)] {
            let conditions = try RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: expensive,
                skipOnConstrainedNetwork: constrained)
            #expect(
                RunConditionEvaluator.evaluate(conditions, environment: try RunEnvironment())
                    == .skipped(.networkStateUnavailable))
            #expect(
                RunConditionEvaluator.evaluate(
                    conditions,
                    environment: try RunEnvironment(isExpensiveNetwork: false, isConstrainedNetwork: false)) == .allowed
            )
            #expect(
                RunConditionEvaluator.evaluate(
                    conditions,
                    environment: try RunEnvironment(isExpensiveNetwork: expensive, isConstrainedNetwork: constrained))
                    == .skipped(expensive ? .expensiveNetwork : .constrainedNetwork))
        }
    }

    @Test func wifiRestrictionCannotBeSilentlyIgnoredWithoutSSIDMonitor() throws {
        let conditions = try RunConditions(
            requiresACPower: false, skipOnExpensiveNetwork: false,
            skipOnConstrainedNetwork: false, allowedWiFiSSIDs: ["Test"])
        #expect(
            RunConditionEvaluator.evaluate(conditions, environment: try RunEnvironment())
                == .skipped(.wifiConditionUnavailable))
    }
}
