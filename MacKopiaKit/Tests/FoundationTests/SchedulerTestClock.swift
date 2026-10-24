import Foundation
import Synchronization

/// Monotonic and wall time advance together under one lock; continuations resume outside it.
final class SchedulerTestClock: Clock, Sendable {
    private struct State {
        var instant = ContinuousClock.now
        var date: Date
        var sleepers: [UUID: (ContinuousClock.Instant, CheckedContinuation<Void, any Error>)] = [:]
    }
    private let state: Mutex<State>
    init(date: Date = Date(timeIntervalSinceReferenceDate: 1_000_000)) { state = Mutex(State(date: date)) }
    var now: ContinuousClock.Instant { state.withLock { $0.instant } }
    var date: Date { state.withLock { $0.date } }
    var minimumResolution: Duration { .nanoseconds(1) }
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    func adjustWallTime(by seconds: Double) {
        state.withLock { $0.date.addTimeInterval(seconds) }
    }

    func advance(_ seconds: Double) {
        let ready = state.withLock { state in
            state.instant += .seconds(seconds)
            state.date.addTimeInterval(seconds)
            let ready = state.sleepers.filter { $0.value.0 <= state.instant }
            for id in ready.keys { state.sleepers.removeValue(forKey: id) }
            return ready.values.map { $0.1 }
        }
        for continuation in ready { continuation.resume() }
    }

    func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let result: Result<Void, any Error>? = state.withLock { state in
                    if Task.isCancelled { return .failure(CancellationError()) }
                    if deadline <= state.instant { return .success(()) }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.sleepers.removeValue(forKey: id)?.1 }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
