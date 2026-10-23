import Foundation
import Testing

@testable import AgentProtocol

@Test func serviceNamesFollowValidatedAppIdentity() throws {
    let identity = try AgentServiceIdentity(appBundleID: "com.example.MacKopia")
    #expect(identity.agentBundleID == "com.example.MacKopia.Agent")
    #expect(identity.machServiceName == "com.example.MacKopia.Agent.xpc")
    #expect(identity.plistName == "com.example.MacKopia.Agent.plist")
    _ = try AgentServiceIdentity(appBundleID: "com." + String(repeating: "a", count: 113))
    #expect(throws: AgentServiceError.invalidIdentity) {
        try AgentServiceIdentity(appBundleID: "com." + String(repeating: "a", count: 114))
    }
    for invalid in [
        "", "one", ".com.example", "com..example", "com.example.", "com.example/agent", "com.ü",
        String(repeating: "a", count: 201) + ".b",
    ] {
        #expect(throws: AgentServiceError.invalidIdentity) { try AgentServiceIdentity(appBundleID: invalid) }
    }
}

@Test func pingRoundTripPreservesVersionAndCorrelation() throws {
    let request = AgentPingRequest()
    let decoded = try JSONDecoder().decode(AgentPingRequest.self, from: JSONEncoder().encode(request))
    #expect(decoded == request)
    let reply = AgentPingReply(request: decoded)
    let decodedReply = try JSONDecoder().decode(AgentPingReply.self, from: JSONEncoder().encode(reply))
    try decodedReply.validate(for: request)
    #expect(decodedReply.status == .ready)
}

@Test func incompatibleOrUnrelatedPingIsRejected() throws {
    let outdated = AgentPingRequest(protocolVersion: 0)
    let reply = AgentPingReply(request: outdated)
    #expect(reply.status == .incompatibleVersion)
    #expect(throws: AgentServiceError.incompatibleProtocol) { try reply.validate(for: outdated) }
    #expect(throws: AgentServiceError.invalidReply) { try reply.validate(for: AgentPingRequest()) }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AgentPingRequest.self, from: Data(#"{"protocolVersion":1,"nonce":"invalid"}"#.utf8))
    }
}

@Test func firstExchangeResultWinsEvenBeforeContinuationInstallation() async throws {
    let exchange = AgentPingExchange()
    let reply = AgentPingReply(request: AgentPingRequest())
    exchange.finish(.success(reply))
    exchange.finish(.failure(AgentServiceError.timedOut))
    let received = try await withCheckedThrowingContinuation { exchange.install($0) }
    #expect(received == reply)
}

@Test func competingExchangeResultsResumeOnlyOnce() async throws {
    let exchange = AgentPingExchange()
    let reply = AgentPingReply(request: AgentPingRequest())
    let received = try await withCheckedThrowingContinuation { continuation in
        exchange.install(continuation)
        Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<64 { group.addTask { exchange.finish(.success(reply)) } }
            }
        }
    }
    #expect(received == reply)
}

@Test func cancellationCanWinBeforeContinuationInstallation() async {
    let exchange = AgentPingExchange()
    exchange.finish(.failure(CancellationError()))
    await #expect(throws: CancellationError.self) {
        try await withCheckedThrowingContinuation { exchange.install($0) }
    }
}

@Test func wrongOwnSigningIdentityPreventsAnyXPCStart() async throws {
    let identity = try AgentServiceIdentity(appBundleID: "invalid.test.Peer")
    let server = AgentPingServer()
    await #expect(throws: AgentServiceError.signingRequired) { try await server.start(identity: identity) }
    let client = AgentPingClient(identity: identity)
    await #expect(throws: AgentServiceError.signingRequired) { try await client.ping() }
}

@Test @MainActor func wrongOwnSigningIdentityPreventsRegistration() throws {
    let identity = try AgentServiceIdentity(appBundleID: "invalid.test.Peer")
    let registration = AgentServiceRegistration(identity: identity)
    #expect(throws: AgentServiceError.signingRequired) { try registration.register() }
}
