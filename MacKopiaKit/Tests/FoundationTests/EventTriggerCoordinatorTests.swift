import BackupDomain
import Foundation
import SystemIntegration
import Testing

@testable import BackupEngine

struct EventTriggerCoordinatorTests {
    @Test func mountMatchesSourceOrDestinationAndDebouncesAllRelevantEdges() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture()
        let manual = try fixture.plan(triggers: [.manual])
        let disabled = try fixture.plan(enabled: false)
        let configuration = try BackupConfiguration(
            repositories: [fixture.repository], plans: [fixture.backup, manual, disabled])
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, received: received)
        await coordinator.replace(configuration: configuration)
        await coordinator.receive(.volumeMounted(uuid: UUID().uuidString))
        #expect(time.sleeperCount == 0)
        await coordinator.receive(.volumeMounted(uuid: fixture.source.uuid.lowercased()))
        try await wait { time.sleeperCount == 1 }
        time.advance(9)
        #expect(await received.requests.isEmpty)
        await coordinator.receive(.volumeMounted(uuid: fixture.destination.uuid))
        try await wait { time.sleeperCount == 1 }
        time.advance(9)
        #expect(await received.requests.isEmpty)
        time.advance(1)
        try await wait { await coordinator.isIdle }
        #expect(await received.requests.map(\.planID) == [fixture.backup.id])
        #expect(await received.requests.first?.trigger == .onVolumeMount)
        await coordinator.stop()
    }

    @Test func loginGateUnmountAndConfigurationReplacementSuppressPendingRequests() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture()
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, loginDate: time.date, received: received)
        await coordinator.replace(configuration: fixture.configuration)
        await coordinator.receive(.volumeMounted(uuid: fixture.source.uuid))
        try await wait { time.sleeperCount == 1 }
        time.advance(59)
        #expect(await received.requests.isEmpty)
        await coordinator.receive(.volumeUnmounted(uuid: fixture.source.uuid))
        #expect(time.sleeperCount == 0)
        time.advance(1)
        await coordinator.receive(.volumeMounted(uuid: fixture.destination.uuid))
        try await wait { time.sleeperCount == 1 }
        try await coordinator.replace(configuration: BackupConfiguration())
        time.advance(600)
        #expect(await coordinator.isIdle)
        #expect(await received.requests.isEmpty)
        await coordinator.stop()
    }

    @Test func reachableNetworkTargetsShareOneProbeAndLocalDestinationsNeverProbe() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let second = try fixture.plan(triggers: [.onNetworkReachable])
        let local = try TriggerFixture()
        let localNetwork = try local.plan(triggers: [.onNetworkReachable])
        let config = try BackupConfiguration(
            repositories: [fixture.repository, local.repository], plans: [fixture.backup, second, localNetwork])
        let probe = TriggerReachability()
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, probe: probe, received: received)
        await coordinator.replace(configuration: config)
        await coordinator.receive(.network(network()))
        try await wait { await coordinator.isIdle }
        #expect(await probe.targets.count == 1)
        #expect(Set(await received.requests.map(\.planID)) == [fixture.backup.id, second.id])
        await coordinator.receive(.network(network()))
        #expect(await coordinator.isIdle)
        #expect(await probe.targets.count == 1)
        await coordinator.stop()
    }

    @Test func unreachableAndRestrictedNetworksNeverEnqueue() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let probe = TriggerReachability(mode: .deny)
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, probe: probe, received: received)
        await coordinator.replace(configuration: fixture.configuration)
        await coordinator.receive(.network(network(expensive: true)))
        try await wait { await coordinator.isIdle }
        #expect(await probe.targets.isEmpty)
        await coordinator.receive(.network(network(available: false)))
        await coordinator.receive(.network(network()))
        try await wait { await coordinator.isIdle }
        #expect(await probe.targets.count == 1)
        #expect(await received.requests.isEmpty)
        await coordinator.stop()
    }

    @Test(arguments: [false, true])
    func networkLossOrReconfigurationDiscardsEvenALateSuccessfulProbeAndJoinsCleanup(reconfigure: Bool) async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let probe = TriggerReachability(mode: .lateSuccess)
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, probe: probe, received: received)
        await coordinator.replace(configuration: fixture.configuration)
        await coordinator.receive(.network(network()))
        try await wait { await probe.targets.count == 1 }
        if reconfigure {
            try await coordinator.replace(configuration: BackupConfiguration())
        } else {
            await coordinator.receive(.network(network(available: false)))
        }
        #expect(await probe.cleaned == 1)
        #expect(await coordinator.isIdle)
        #expect(await received.requests.isEmpty)
        #expect(await received.failures == 0)
        await coordinator.stop()
    }

    @Test(arguments: ["unknown", "constrained", "wifi"])
    func unknownOrConstrainedNetworkAndUnsupportedWiFiRestrictionNeverProbe(mode: String) async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let conditions = try RunConditions(
            requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: true,
            allowedWiFiSSIDs: mode == "wifi" ? ["SyntheticNetwork"] : nil)
        let plan = try fixture.plan(triggers: [.onNetworkReachable], conditions: conditions)
        let probe = TriggerReachability()
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, probe: probe, received: received)
        try await coordinator.replace(
            configuration: BackupConfiguration(repositories: [fixture.repository], plans: [plan]))
        let path =
            mode == "unknown"
            ? NetworkPathObservation()
            : NetworkPathObservation(isExpensive: false, isConstrained: mode == "constrained")
        await coordinator.receive(
            .network(SystemNetworkObservation(isAvailable: true, path: path, interfaces: [.wifi])))
        try await wait { await coordinator.isIdle }
        #expect(await probe.targets.isEmpty)
        #expect(await received.requests.isEmpty)
        await coordinator.stop()
    }

    @Test func stopCancelsAndJoinsProbeAndIgnoresSubsequentEvents() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let probe = TriggerReachability(mode: .waitForCancellation)
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, probe: probe, received: received)
        await coordinator.replace(configuration: fixture.configuration)
        await coordinator.receive(.network(network()))
        try await wait { await probe.targets.count == 1 }
        await coordinator.stop()
        #expect(await probe.cleaned == 1)
        #expect(await coordinator.isIdle)
        await coordinator.receive(.network(network()))
        #expect(await probe.targets.count == 1)
        #expect(await received.requests.isEmpty)
    }

    @Test func admissionFailuresAreReportedAndStopFromReceiverDoesNotDeadlock() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, received: received, reject: true)
        await coordinator.replace(configuration: fixture.configuration)
        await coordinator.receive(.network(network()))
        try await wait { await coordinator.isIdle }
        #expect(await received.failures == 1)
        await coordinator.stop()
        let holder = TriggerCoordinatorHolder()
        let stopping = EventTriggerCoordinator(
            loginDate: time.date.addingTimeInterval(-60), clock: time, now: { time.date },
            reachability: TriggerReachability(),
            admit: { _, _, _ in await holder.stop() }, failed: { _, error in Issue.record(error) })
        await holder.set(stopping)
        await stopping.replace(configuration: fixture.configuration)
        await stopping.receive(.network(network()))
        try await wait { await stopping.isIdle }
    }

    @Test func suppressingOnePlanPreservesOtherMountDeadlineAndRequiresFreshEvidenceAfterResume() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture()
        let second = try fixture.plan()
        let received = TriggerAdmissions()
        let coordinator = coordinator(time, received: received)
        try await coordinator.replace(
            configuration: BackupConfiguration(repositories: [fixture.repository], plans: [fixture.backup, second]))
        await coordinator.receive(.volumeMounted(uuid: fixture.source.uuid))
        try await wait { time.sleeperCount == 1 }
        time.advance(9)
        await coordinator.setSuppressed(planID: fixture.backup.id, true)
        try await wait { time.sleeperCount == 1 }
        time.advance(1)
        try await wait { await coordinator.isIdle }
        #expect(await received.requests.map(\.planID) == [second.id])
        await coordinator.setSuppressed(planID: fixture.backup.id, false)
        #expect(await coordinator.isIdle)
        await coordinator.receive(.volumeMounted(uuid: fixture.source.uuid))
        try await wait { time.sleeperCount == 1 }
        time.advance(10)
        try await wait { await coordinator.isIdle }
        #expect(await received.requests.count == 3)
        #expect(await received.requests.contains { $0.planID == fixture.backup.id })
        await coordinator.stop()
    }

    @Test func pauseAndResumeDuringSharedProbeDiscardsOldPlanEvidenceButPreservesOtherPlan() async throws {
        let time = SchedulerTestClock()
        let fixture = try TriggerFixture(remote: true)
        let second = try fixture.plan(triggers: [.onNetworkReachable])
        let received = TriggerAdmissions()
        let probe = TriggerReachability(mode: .heldSuccess)
        let coordinator = coordinator(time, probe: probe, received: received)
        try await coordinator.replace(
            configuration: BackupConfiguration(repositories: [fixture.repository], plans: [fixture.backup, second]))
        await coordinator.receive(.network(network()))
        try await wait { await probe.targets.count == 1 }
        await coordinator.setSuppressed(planID: fixture.backup.id, true)
        await coordinator.setSuppressed(planID: fixture.backup.id, false)
        await probe.succeed()
        try await wait { await coordinator.isIdle }
        #expect(await received.requests.map(\.planID) == [second.id])
        #expect(await probe.targets.count == 1)
        await coordinator.stop()
    }

    private func coordinator(
        _ time: SchedulerTestClock, loginDate: Date? = nil, probe: TriggerReachability = TriggerReachability(),
        received: TriggerAdmissions, reject: Bool = false
    ) -> EventTriggerCoordinator<SchedulerTestClock> {
        EventTriggerCoordinator(
            loginDate: loginDate ?? time.date.addingTimeInterval(-60), clock: time, now: { time.date },
            reachability: probe,
            admit: { _, _, request in
                if reject { throw JobAdmissionError.configurationChanged }
                await received.append(request)
            }, failed: { _, _ in await received.failed() })
    }

    private func network(available: Bool = true, expensive: Bool = false) -> SystemNetworkObservation {
        SystemNetworkObservation(
            isAvailable: available, path: NetworkPathObservation(isExpensive: expensive, isConstrained: false),
            interfaces: [.wifi])
    }

    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}
