import BackupDomain
import LightweightCodeRequirements
import Synchronization
import XPC

public actor AgentServiceServer {
    private var listener: XPCListener?
    public init() {}

    public func start(
        identity: AgentServiceIdentity,
        handle: @escaping @Sendable (AgentRequest.Command) async throws -> LocalServiceState
    ) throws {
        guard listener == nil else { return }
        let requirement = try AgentSigningIdentity.peerRequirement(identity: identity, role: .agent)
        listener = try XPCListener(service: identity.machServiceName, requirement: .codeRequirement(requirement)) {
            request in
            request.accept { session in ServicePeer(session: session, handle: handle) }
        }
    }

    public func stop() { listener?.cancel(); listener = nil }
}

/// One request per authenticated session. Disconnect cancels observation/validation, not an admitted backup.
final class ServicePeer: XPCPeerHandler, Sendable {
    typealias Input = AgentWirePacket
    typealias Output = any Encodable
    private struct Work {
        var submitted = false
        var cancelled = false
        var task: Task<Void, Never>?
    }
    private let work = Mutex(Work())
    private let session: XPCSession
    private let handle: @Sendable (AgentRequest.Command) async throws -> LocalServiceState

    init(session: XPCSession, handle: @escaping @Sendable (AgentRequest.Command) async throws -> LocalServiceState) {
        self.session = session
        self.handle = handle
    }

    func handleIncomingRequest(_ packet: AgentWirePacket) -> (any Encodable)? {
        work.withLock { work in
            guard !work.submitted, !work.cancelled else { return }
            work.submitted = true
            work.task = Task { [handle, session] in
                guard let message = try? packet.decode(AgentRequest.self, limit: 1_048_576) else {
                    session.cancel(reason: "Invalid bounded request"); return
                }
                let response: AgentResponse
                do {
                    try Task.checkCancellation()
                    try message.validate()
                    response = AgentResponse(id: message.id, state: try await handle(message.command))
                } catch {
                    response = AgentResponse(
                        id: message.id,
                        issue: error as? LocalServiceIssue
                            ?? (error is DomainValidationError ? .invalidRequest : .unavailable))
                }
                if let packet = try? AgentWirePacket(response) {
                    try? session.send(packet)
                } else {
                    session.cancel(reason: "Response exceeds limit")
                }
            }
        }
        return nil
    }

    func handleCancellation(error: XPCRichError) {
        work.withLock { work in
            work.cancelled = true; work.task?.cancel(); work.task = nil
        }
    }
}
