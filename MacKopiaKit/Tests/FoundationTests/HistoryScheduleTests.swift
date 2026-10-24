import BackupDomain
import Foundation
import Persistence
import Testing

@testable import BackupEngine

struct HistoryScheduleTests {
    @Test func anchorsSurviveReopenIgnoreUnsuccessfulFutureAndOtherDestinationRuns() async throws {
        let fixture = try PreflightTestFixture()
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try HistoryStore(directory: root)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let older = now.addingTimeInterval(-600)
        let warning = now.addingTimeInterval(-300)
        for (outcome, date, repository) in [
            (JobRun.Outcome.succeeded, older, fixture.repository.id),
            (.succeededWithWarnings, warning, fixture.repository.id),
            (.failed, now, fixture.repository.id), (.cancelled, now, fixture.repository.id),
            (.skipped, now, fixture.repository.id), (.running, now, fixture.repository.id),
            (.succeeded, now.addingTimeInterval(600), fixture.repository.id),
            (.succeeded, now, UUID()),
        ] {
            try await record(store, plan: fixture.plan, repositoryID: repository, date: date, outcome: outcome)
        }
        // A paginated recent-history implementation would lose the older successful anchor.
        for index in 0..<105 {
            try await record(store, plan: fixture.plan, date: now.addingTimeInterval(-Double(index)), outcome: .running)
        }
        let reopened = try HistoryStore(directory: root)
        #expect(try await reopened.scheduleAnchors(plans: [fixture.plan], before: now) == [fixture.plan.id: warning])
        #expect(try await reopened.scheduleAnchors(plans: [], before: now).isEmpty)
        await #expect(throws: ConfigStoreError.invalidConfiguration) {
            try await reopened.scheduleAnchors(plans: [fixture.plan, fixture.plan], before: now)
        }
        await #expect(throws: ConfigStoreError.invalidConfiguration) {
            try await reopened.scheduleAnchors(plans: [fixture.plan], before: Date(timeIntervalSince1970: .infinity))
        }
    }

    @Test func durableAnchorDrivesOneCatchUpThroughAutomaticEngine() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.interval(minutes: 1)])
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(directory: root)
        try await record(
            history, plan: fixture.plan, date: fixture.time.date.addingTimeInterval(-600), outcome: .succeeded)
        let runtime = try fixture.runtime(historyOverride: HistoryStore(directory: root))
        try await runtime.start()
        #expect(await runtime.scheduler.nextRunDate == fixture.time.date.addingTimeInterval(120))
        try await waitForRuntime { await fixture.monitor.observing && fixture.time.sleeperCount == 1 }
        fixture.time.advance(119)
        #expect(await fixture.sessions.opens == 0)
        fixture.time.advance(1)
        try await waitForRuntime { (try? await history.recent().filter { $0.outcome == .succeeded }.count) == 2 }
        #expect(await fixture.sessions.opens == 1)
        await runtime.shutdown()
        #expect(fixture.time.sleeperCount == 0)
    }

    @Test func explicitEmptyAnchorsOverrideHistoryAndReadFailurePreventsStartup() async throws {
        let fixture = try await AutomaticRuntimeFixture(triggers: [.interval(minutes: 1)])
        let failing = FailingScheduleHistory()
        let runtime = try fixture.runtime(historyOverride: failing)
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await runtime.start() }
        #expect(await runtime.state == .stopped)
        #expect(await fixture.monitor.observing == false)
        #expect(await fixture.sessions.opens == 0)
        #expect(fixture.time.sleeperCount == 0)
        let explicit = try fixture.runtime(historyOverride: failing)
        try await explicit.start(lastRuns: [:])
        #expect(await explicit.scheduler.nextRunDate == fixture.time.date.addingTimeInterval(60))
        await explicit.shutdown()
    }

    @Test func shutdownDuringHistoryReadCannotStartMonitoringOrScheduler() async throws {
        let fixture = try await AutomaticRuntimeFixture()
        let history = HeldScheduleHistory()
        let runtime = try fixture.runtime(historyOverride: history)
        let starting = Task { try await runtime.start() }
        try await waitForRuntime { await history.reading }
        await runtime.shutdown()
        await history.release()
        await #expect(throws: CancellationError.self) { try await starting.value }
        #expect(await runtime.state == .stopped)
        #expect(await fixture.monitor.observing == false)
        #expect(await fixture.sessions.opens == 0)
        #expect(fixture.time.sleeperCount == 0)
    }

    private func record(
        _ history: HistoryStore, plan: BackupPlan, repositoryID: UUID? = nil, date: Date, outcome: JobRun.Outcome
    ) async throws {
        let id = UUID()
        func run(_ state: JobRun.Outcome) -> JobRun {
            JobRun(
                id: id, planID: plan.id, repositoryID: repositoryID ?? plan.repositoryID, trigger: .manual,
                startedAt: date, endedAt: date.addingTimeInterval(10), outcome: state, sources: [], issues: [])
        }
        try await history.begin(run(.running))
        if outcome != .running { try await history.finish(run(outcome)) }
    }
}

private struct FailingScheduleHistory: JobHistoryRecording, JobHistoryScheduleReading {
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func scheduleAnchors(plans: [BackupPlan], before: Date) throws -> [UUID: Date] {
        throw ConfigStoreError.storageUnavailable
    }
}

private actor HeldScheduleHistory: JobHistoryRecording, JobHistoryScheduleReading {
    var reading = false
    private var continuation: CheckedContinuation<Void, Never>?
    func begin(_ run: JobRun) {}
    func finish(_ run: JobRun) {}
    func scheduleAnchors(plans: [BackupPlan], before: Date) async -> [UUID: Date] {
        reading = true
        await withCheckedContinuation { continuation = $0 }
        return [:]
    }
    func release() { continuation?.resume(); continuation = nil }
}
