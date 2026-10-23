import Synchronization

/// Cancellation records intent only. The lifecycle task is the sole PID owner and signal sender.
final class KopiaProcessControl: Sendable {
    enum Stop: Sendable { case cancelled, timedOut, outputLimit, ioFailure }
    private struct State: Sendable {
        var stop: Stop?
        var exited = false
    }
    private let state = Mutex(State())

    func stop(_ reason: Stop) {
        state.withLock { if $0.stop == nil { $0.stop = reason } }
    }

    var reason: Stop? { state.withLock { $0.stop } }
    var exited: Bool { state.withLock { $0.exited } }
    func didExit() { state.withLock { $0.exited = true } }
}
