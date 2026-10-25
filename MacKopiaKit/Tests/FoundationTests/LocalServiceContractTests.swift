import BackupDomain
import Foundation
import Testing

@testable import AgentProtocol

struct LocalServiceContractTests {
    @Test func setupRejectsEmptyOversizedAndWeakInputWithoutEchoingCredentials() throws {
        let marker = UUID().uuidString
        let valid = AgentRequest(
            .setup(
                name: "Test", destination: try selection("/tmp/destination"), source: try selection("/tmp/source"),
                password: marker, create: true))
        try valid.validate()
        #expect(!String(reflecting: valid).contains(marker))
        for request in [
            AgentRequest(
                .setup(
                    name: "", destination: try selection("/tmp/d"), source: try selection("/tmp/s"), password: marker,
                    create: true)),
            AgentRequest(
                .setup(
                    name: "Bad\0name", destination: try selection("/tmp/d"), source: try selection("/tmp/s"),
                    password: marker, create: true)),
            AgentRequest(
                .setup(
                    name: "Test", destination: try selection("/tmp/d"), source: try selection("/tmp/s"),
                    password: "short", create: true)),
            AgentRequest(
                .setup(
                    name: "Test", destination: try selection("/tmp/d"), source: try selection("/tmp/s"),
                    password: String(repeating: "a", count: 65_537), create: false)),
        ] {
            #expect(throws: LocalServiceIssue.invalidRequest) { try request.validate() }
        }
        #expect(throws: AgentServiceError.incompatibleProtocol) {
            try AgentRequest(.state(after: nil), version: 0).validate()
        }
    }

    @Test func wireBoundsPayloadBeforeDomainDecodingAndKeepsCorrelation() throws {
        let request = AgentRequest(.run(UUID()))
        let packet = try AgentWirePacket(request)
        let decoded = try packet.decode(AgentRequest.self)
        #expect(decoded.id == request.id)
        #expect(decoded.version == AgentRequest.currentVersion)
        #expect(throws: AgentServiceError.invalidReply) { try packet.decode(AgentRequest.self, limit: 1) }
        #expect(throws: AgentServiceError.invalidReply) { try AgentWirePacket(request, limit: 1) }
        let oversize = try JSONEncoder().encode(Data(count: 16_777_217))
        #expect(throws: AgentServiceError.invalidReply) {
            try JSONDecoder().decode(AgentWirePacket.self, from: oversize)
        }
    }

    @Test func stateAndResponseDoNotContainSetupSecretAndHistoryIsBounded() throws {
        let state = LocalServiceState(configuration: try BackupConfiguration(), issue: .permissions)
        let response = AgentResponse(id: UUID(), state: state)
        let roundtrip = try AgentWirePacket(response).decode(AgentResponse.self)
        #expect(roundtrip.state?.issue == .permissions)
        #expect(roundtrip.id == response.id)
        #expect(roundtrip.version == AgentRequest.currentVersion)
        #expect(roundtrip.state?.revision == state.revision)
    }
    @Test func automationCommandsAreVersionedAndRejectInvalidDates() throws {
        let id = UUID()
        for command in [
            AgentRequest.Command.pause(planID: id, until: .now), .resume(planID: id),
            .verify(id), .setNotificationsEnabled(true),
        ] {
            let request = AgentRequest(command)
            try AgentWirePacket(request).decode(AgentRequest.self).validate()
        }
        #expect(throws: LocalServiceIssue.invalidRequest) {
            try AgentRequest(.pause(planID: nil, until: Date(timeIntervalSinceReferenceDate: .infinity))).validate()
        }
        #expect(throws: AgentServiceError.incompatibleProtocol) {
            try AgentRequest(.state(after: nil), version: 2).validate()
        }
    }

    private func selection(_ path: String) throws -> BackupSource {
        try BackupSource(
            path: path,
            volume: VolumeIdentity(
                uuid: "11111111-1111-1111-1111-111111111111", name: "Test", isRemovable: false, isNetwork: false))
    }

}
