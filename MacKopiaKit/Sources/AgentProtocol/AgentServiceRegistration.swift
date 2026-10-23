import ServiceManagement

/// App-side lifecycle boundary. Registration is explicit, never a side effect of reading status.
@MainActor
public struct AgentServiceRegistration {
    public enum Status: Sendable, Equatable { case notRegistered, enabled, requiresApproval, notFound }
    private let service: any AgentServiceManaging
    private let validateSignature: () throws -> Void

    public init(identity: AgentServiceIdentity) {
        service = SystemAgentService(service: .agent(plistName: identity.plistName))
        validateSignature = { try AgentSigningIdentity.requireTeamSignature(signingIdentifier: identity.appBundleID) }
    }

    // Internal injection is only for tests; the public initializer always verifies the running signature.
    init(service: any AgentServiceManaging, validateSignature: @escaping () throws -> Void) {
        self.service = service
        self.validateSignature = validateSignature
    }

    public var status: Status { service.status }

    public func register() throws {
        try validateSignature()
        switch status {
        case .enabled, .requiresApproval: return
        case .notFound: throw AgentServiceError.unavailable
        case .notRegistered:
            do { try service.register() } catch {
                // SMAppService may report launch denial after recording a request for user approval.
                guard status == .requiresApproval else { throw AgentServiceError.registrationFailed }
            }
        }
    }

    public func openLoginItemsSettings() { service.openLoginItemsSettings() }
}
