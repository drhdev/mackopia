import Testing

@testable import AgentProtocol

@MainActor
private final class FakeService: AgentServiceManaging {
    var status: AgentServiceRegistration.Status = .notRegistered
    var registerCalls = 0
    var settingsCalls = 0
    var failure: AgentServiceError?
    var afterRegister: AgentServiceRegistration.Status = .enabled

    func register() throws {
        registerCalls += 1
        status = afterRegister
        if let failure { throw failure }
    }

    func openLoginItemsSettings() { settingsCalls += 1 }
}

@Test @MainActor func readingServiceStatusDoesNotRegister() {
    let service = FakeService()
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    #expect(registration.status == .notRegistered)
    #expect(service.registerCalls == 0)
    registration.openLoginItemsSettings()
    #expect(service.settingsCalls == 1)
}

@Test @MainActor func signatureFailureNeverReachesServiceManager() {
    let service = FakeService()
    let registration = AgentServiceRegistration(service: service) { throw AgentServiceError.signingRequired }
    #expect(throws: AgentServiceError.signingRequired) { try registration.register() }
    #expect(service.registerCalls == 0)
}

@Test @MainActor func enabledOrPendingRegistrationIsNotRepeated() throws {
    let service = FakeService()
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    try registration.register()
    #expect(registration.status == .enabled)
    try registration.register()
    #expect(service.registerCalls == 1)
    service.status = .requiresApproval
    try registration.register()
    #expect(service.registerCalls == 1)
}

@Test @MainActor func pendingApprovalRemainsActionableAfterLaunchDenial() throws {
    let service = FakeService()
    service.afterRegister = .requiresApproval
    service.failure = .unavailable
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    try registration.register()
    #expect(registration.status == .requiresApproval)
    #expect(service.registerCalls == 1)
}

@Test @MainActor func missingJobAndRegistrationFailuresAreTyped() {
    let service = FakeService()
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    service.status = .notRegistered
    service.afterRegister = .notRegistered
    service.failure = .invalidReply
    #expect(throws: AgentServiceError.registrationFailed) { try registration.register() }
    #expect(service.registerCalls == 1)
}

@Test @MainActor func missingStatusStillAllowsExplicitRegistration() throws {
    let service = FakeService()
    service.status = .notFound
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    try registration.register()
    #expect(service.registerCalls == 1)
    #expect(registration.status == .enabled)
}

@Test @MainActor func missingServiceRegistrationStillReportsSystemFailure() {
    let service = FakeService()
    service.status = .notFound
    service.afterRegister = .notFound
    service.failure = .unavailable
    let registration = AgentServiceRegistration(service: service, validateSignature: {})
    #expect(throws: AgentServiceError.registrationFailed) { try registration.register() }
    #expect(service.registerCalls == 1)
}
