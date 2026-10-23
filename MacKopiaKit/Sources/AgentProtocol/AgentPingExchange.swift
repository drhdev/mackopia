import Synchronization

/// Reply, timeout and cancellation race; only the first result may resume the continuation.
final class AgentPingExchange: Sendable {
    private struct State {
        var continuation: CheckedContinuation<AgentPingReply, any Error>?
        var result: Result<AgentPingReply, any Error>?
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<AgentPingReply, any Error>) {
        let result: Result<AgentPingReply, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func finish(_ result: Result<AgentPingReply, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return Optional<CheckedContinuation<AgentPingReply, any Error>>.none }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
