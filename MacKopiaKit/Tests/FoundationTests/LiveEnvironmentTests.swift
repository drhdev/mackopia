import BackupDomain
import BackupEngine
import Foundation
import Testing

@testable import SystemIntegration

struct LiveEnvironmentTests {
    @Test func powerReadingsDistinguishUnknownDesktopBatteryAndUPS() {
        #expect(power(nil).hasBattery == nil)
        #expect(power([]).hasBattery == false)
        #expect(power([reading(.ups)]).hasBattery == false)
        #expect(power([reading(.unknown)]).hasBattery == nil)
        let battery = power([reading(.internalBattery, current: 31, maximum: 60)])
        #expect(battery.hasBattery == true)
        #expect(battery.batteryPercent == 51)
        #expect(power([reading(.internalBattery, current: 1, maximum: 100)]).batteryPercent == 1)
        #expect(power([reading(.internalBattery, current: 0, maximum: 100)]).batteryPercent == 0)
        #expect(power([reading(.internalBattery, current: 100, maximum: 100)]).batteryPercent == 100)
    }

    @Test func invalidCapacityCannotSatisfyBatteryRestriction() throws {
        let conditions = try RunConditions(
            requiresACPower: false, minBatteryPercent: 20,
            skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false)
        for (current, maximum, present) in [
            (nil, 100, true), (20, nil, true), (-1, 100, true), (101, 100, true),
            (0, 0, true), (10, -1, true), (Int.max, Int.max, true),
            (100, 100, false), (100, 100, nil),
        ] as [(Int?, Int?, Bool?)] {
            let observation = power([reading(.internalBattery, current: current, maximum: maximum, present: present)])
            #expect(observation.hasBattery == true)
            #expect(observation.batteryPercent == nil)
            let environment = try RunEnvironment(
                hasBattery: observation.hasBattery, batteryPercent: observation.batteryPercent)
            #expect(
                RunConditionEvaluator.evaluate(conditions, environment: environment) == .skipped(.powerStateUnavailable)
            )
        }
    }

    @Test func multipleInternalBatteriesUseMinimumAndRequireEveryCapacity() {
        #expect(
            power([
                reading(.internalBattery, current: 90, maximum: 100),
                reading(.internalBattery, current: 30, maximum: 100),
                reading(.ups, current: 1, maximum: 100),
            ]).batteryPercent == 30)
        #expect(
            power([
                reading(.internalBattery, current: 90, maximum: 100), reading(.internalBattery),
            ]).batteryPercent == nil)
    }

    @Test func malformedNumericValuesDoNotBecomeCapacity() {
        for value: Any? in [nil, true, false, 1.5, "50", NSNumber(value: Double.nan)] {
            #expect(LocalPowerStateSampler.integer(value) == nil)
        }
        #expect(LocalPowerStateSampler.integer(NSNumber(value: 50)) == 50)
        #expect(LocalPowerStateSampler.integer(NSNumber(value: Int.max)) == Int.max)
        #expect(
            power([
                reading(.internalBattery, current: 90, maximum: 100), reading(.unknown),
            ]).batteryPercent == nil)
    }

    @Test func unsatisfiedNetworkNeverAttestsToUnmeteredAccess() {
        for expensive in [true, false] {
            for constrained in [true, false] {
                #expect(
                    NetworkPathObservation(isSatisfied: false, isExpensive: expensive, isConstrained: constrained)
                        == NetworkPathObservation())
                #expect(
                    NetworkPathObservation(isSatisfied: true, isExpensive: expensive, isConstrained: constrained)
                        == NetworkPathObservation(isExpensive: expensive, isConstrained: constrained))
            }
        }
    }

    @Test func environmentSamplesAgainWithoutCachingAndKeepsConditionsIndependent() async throws {
        let power = CountingPower()
        let sampler = LocalRunEnvironmentSampler(power: power, network: FixedNetwork())
        let first = try await sampler.sample()
        let second = try await sampler.sample()
        #expect(first.batteryPercent == 10)
        #expect(second.batteryPercent == 20)
        #expect(first.isOnACPower == true)
        #expect(first.isLowPowerMode == true)
        #expect(first.isExpensiveNetwork == false)
        #expect(first.isConstrainedNetwork == true)
        let ac = try RunConditions(
            requiresACPower: true, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false)
        #expect(RunConditionEvaluator.evaluate(ac, environment: first) == .skipped(.lowPowerMode))
        let constrained = try RunConditions(
            requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: true)
        #expect(RunConditionEvaluator.evaluate(constrained, environment: first) == .skipped(.constrainedNetwork))
    }

    @Test func networkDeadlineCancelsAndJoinsObservation() async throws {
        let cleanup = CleanupProbe()
        let sampler = LocalNetworkPathSampler(clock: ImmediateClock()) {
            do {
                try await Task.sleep(for: .seconds(60))
                Issue.record("Deadline failed to cancel observation")
            } catch {
                await cleanup.record()
                throw error
            }
            return NetworkPathObservation(isExpensive: false, isConstrained: false)
        }
        #expect(try await sampler.sampleNetwork() == NetworkPathObservation())
        #expect(await cleanup.finished)
    }

    @Test func firstNetworkResultCancelsDeadlineAndDoesNotCache() async throws {
        let cleanup = CleanupProbe()
        let clock = RecordingClock(cleanup: cleanup)
        let sampler = LocalNetworkPathSampler(clock: clock) {
            NetworkPathObservation(isExpensive: true, isConstrained: false)
        }
        for _ in 0..<2 {
            #expect(
                try await sampler.sampleNetwork() == NetworkPathObservation(isExpensive: true, isConstrained: false))
        }
        #expect(await cleanup.finished)
    }

    @Test func cancellationPropagatesBeforeAndDuringNativeObservations() async throws {
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await LocalPowerStateSampler().samplePower() }
            await #expect(throws: CancellationError.self) { try await LocalNetworkPathSampler().sampleNetwork() }
            await #expect(throws: CancellationError.self) { try await LocalRunEnvironmentSampler().sample() }
        }
        await cancelled.value
        let started = CleanupProbe()
        let sampler = LocalNetworkPathSampler(clock: ContinuousClock()) {
            await started.record()
            try await Task.sleep(for: .seconds(60))
            return NetworkPathObservation()
        }
        let task = Task { try await sampler.sampleNetwork() }
        await started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func nativeAdaptersReturnBoundedObservationsWithoutDestinationConnections() async throws {
        let power = try await LocalPowerStateSampler().samplePower()
        #expect(power.batteryPercent.map { (0...100).contains($0) } ?? true)
        #expect(power.hasBattery != false || power.batteryPercent == nil)
        let network = try await LocalNetworkPathSampler().sampleNetwork()
        #expect((network.isExpensive == nil) == (network.isConstrained == nil))
    }

    private func reading(
        _ kind: PowerSourceReading.Kind, current: Int? = nil, maximum: Int? = nil, present: Bool? = true
    ) -> PowerSourceReading {
        PowerSourceReading(kind: kind, current: current, maximum: maximum, isPresent: present)
    }

    private func power(_ sources: [PowerSourceReading]?) -> PowerStateObservation {
        PowerStateObservation(onACPower: nil, sources: sources, lowPowerMode: false)
    }
}

private actor CountingPower: PowerStateSampling {
    private var count = 0
    func samplePower() async throws -> PowerStateObservation {
        count += 1
        return PowerStateObservation(
            onACPower: true,
            sources: [
                PowerSourceReading(kind: .internalBattery, current: count * 10, maximum: 100, isPresent: true)
            ], lowPowerMode: true)
    }
}

private struct FixedNetwork: NetworkPathSampling {
    func sampleNetwork() async throws -> NetworkPathObservation {
        NetworkPathObservation(isExpensive: false, isConstrained: true)
    }
}

private actor CleanupProbe {
    private(set) var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func record() {
        finished = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if finished { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct ImmediateClock: Clock {
    var now: ContinuousClock.Instant { ContinuousClock.now }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {}
}

private struct RecordingClock: Clock {
    let cleanup: CleanupProbe
    var now: ContinuousClock.Instant { ContinuousClock.now }
    var minimumResolution: Duration { .nanoseconds(1) }
    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        do { try await Task.sleep(for: .seconds(60)) } catch {
            await cleanup.record()
            throw error
        }
    }
}
