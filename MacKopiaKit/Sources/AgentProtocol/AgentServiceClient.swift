import BackupDomain
import LightweightCodeRequirements
import Synchronization
import XPC

public actor AgentServiceClient {
    private let identity: AgentServiceIdentity
    public init(identity: AgentServiceIdentity) { self.identity = identity }

    public func send(_ command: AgentRequest.Command) async throws -> LocalServiceState {
        let request = AgentRequest(command)
        try request.validate()
        try Task.checkCancellation()
        let exchange = ServiceExchange()
        let requirement = try AgentSigningIdentity.peerRequirement(identity: identity, role: .app)
        let session = try XPCSession(
            machService: identity.machServiceName, requirement: .codeRequirement(requirement),
            incomingMessageHandler: { (packet: AgentWirePacket) -> (any Encodable)? in
                guard let reply = try? packet.decode(AgentResponse.self) else {
                    exchange.finish(.failure(AgentServiceError.invalidReply)); return nil
                }
                guard reply.id == request.id, reply.version == AgentRequest.currentVersion else {
                    exchange.finish(.failure(AgentServiceError.invalidReply)); return nil
                }
                if let issue = reply.issue {
                    exchange.finish(.failure(issue))
                } else if let state = reply.state {
                    exchange.finish(.success(state))
                } else {
                    exchange.finish(.failure(AgentServiceError.invalidReply))
                }
                return nil
            }, cancellationHandler: { _ in exchange.finish(.failure(AgentServiceError.unavailable)) })
        defer { session.cancel(reason: "Request completed") }
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(90))
                exchange.finish(.failure(AgentServiceError.timedOut))
                session.cancel(reason: "Request deadline")
            } catch {}
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.install(continuation)
                do { try session.send(AgentWirePacket(request, limit: 1_048_576)) } catch {
                    exchange.finish(.failure(AgentServiceError.unavailable))
                }
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
            session.cancel(reason: "Request cancelled")
        }
    }
}

final class ServiceExchange: Sendable {
    private struct State {
        var continuation: CheckedContinuation<LocalServiceState, any Error>?
        var result: Result<LocalServiceState, any Error>?
    }
    private let state = Mutex(State())
    func install(_ continuation: CheckedContinuation<LocalServiceState, any Error>) {
        let result: Result<LocalServiceState, any Error>? = state.withLock { state in
            if let result = state.result { return result }
            state.continuation = continuation
            return Optional<Result<LocalServiceState, any Error>>.none
        }
        if let result { continuation.resume(with: result) }
    }
    func finish(_ result: Result<LocalServiceState, any Error>) {
        let continuation = state.withLock { state in
            guard state.result == nil else { return Optional<CheckedContinuation<LocalServiceState, any Error>>.none }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
