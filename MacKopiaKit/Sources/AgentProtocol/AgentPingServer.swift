import XPC

public actor AgentPingServer {
    private var listener: XPCListener?

    public init() {}

    public func start(identity: AgentServiceIdentity) throws {
        guard listener == nil else { return }
        try AgentSigningIdentity.requireTeamSignature(signingIdentifier: identity.agentBundleID)
        do {
            listener = try XPCListener(
                service: identity.machServiceName,
                requirement: .isFromSameTeam(andMatchesSigningIdentifier: identity.appBundleID)
            ) { request in
                request.accept { (message: AgentPingRequest) -> (any Encodable)? in
                    AgentPingReply(request: message)
                }
            }
        } catch { throw AgentServiceError.unavailable }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
