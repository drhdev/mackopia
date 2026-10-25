import LightweightCodeRequirements
import XPC

public actor AgentPingClient {
    private let identity: AgentServiceIdentity
    private let clock: any Clock<Duration>

    public init(identity: AgentServiceIdentity, clock: any Clock<Duration> = ContinuousClock()) {
        self.identity = identity
        self.clock = clock
    }

    public func ping() async throws -> AgentPingReply {
        try Task.checkCancellation()
        let requirement = try AgentSigningIdentity.peerRequirement(identity: identity, role: .app)
        let session: XPCSession
        do {
            session = try XPCSession(
                machService: identity.machServiceName,
                requirement: .codeRequirement(requirement)
            )
        } catch { throw AgentServiceError.unavailable }
        defer { session.cancel(reason: "Ping completed") }
        let exchange = AgentPingExchange()
        let request = AgentPingRequest()
        let deadline = Task {
            do {
                try await clock.sleep(for: .seconds(5))
                exchange.finish(.failure(AgentServiceError.timedOut))
                session.cancel(reason: "Ping deadline exceeded")
            } catch {}
        }
        defer { deadline.cancel() }
        let reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.install(continuation)
                do {
                    try session.send(request) { (result: Result<AgentPingReply, any Error>) in
                        switch result {
                        case .success(let reply): exchange.finish(.success(reply))
                        case .failure: exchange.finish(.failure(AgentServiceError.unavailable))
                        }
                    }
                } catch { exchange.finish(.failure(AgentServiceError.unavailable)) }
            }
        } onCancel: {
            exchange.finish(.failure(CancellationError()))
            session.cancel(reason: "Ping canceled")
        }
        try reply.validate(for: request)
        return reply
    }
}
