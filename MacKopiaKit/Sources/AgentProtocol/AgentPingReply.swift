import Foundation

public struct AgentPingReply: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case ready, incompatibleVersion }
    public let protocolVersion: UInt32
    public let nonce: UUID
    public let status: Status

    public init(request: AgentPingRequest) {
        protocolVersion = AgentPingRequest.currentVersion
        nonce = request.nonce
        status = request.protocolVersion == protocolVersion ? .ready : .incompatibleVersion
    }

    public func validate(for request: AgentPingRequest) throws {
        guard nonce == request.nonce else { throw AgentServiceError.invalidReply }
        guard status == .ready, protocolVersion == request.protocolVersion else {
            throw AgentServiceError.incompatibleProtocol
        }
    }
}
