import Foundation

public struct AgentPingRequest: Codable, Sendable, Equatable {
    public static let currentVersion: UInt32 = 1
    public let protocolVersion: UInt32
    public let nonce: UUID

    public init(protocolVersion: UInt32 = Self.currentVersion, nonce: UUID = UUID()) {
        self.protocolVersion = protocolVersion
        self.nonce = nonce
    }
}
