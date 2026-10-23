import ServiceManagement

@MainActor
protocol AgentServiceManaging {
    var status: AgentServiceRegistration.Status { get }
    func register() throws
    func openLoginItemsSettings()
}

@MainActor
struct SystemAgentService: AgentServiceManaging {
    let service: SMAppService

    var status: AgentServiceRegistration.Status {
        switch service.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() throws { try service.register() }
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}
