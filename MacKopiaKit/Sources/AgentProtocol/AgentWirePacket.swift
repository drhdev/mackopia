import Foundation

/// Bound serialized input before decoding arrays, paths or credentials into domain objects.
struct AgentWirePacket: Codable, Sendable, CustomReflectable {
    let payload: Data
    init<T: Encodable>(_ value: T, limit: Int = 16_777_216) throws {
        payload = try JSONEncoder().encode(value)
        guard payload.count <= limit else { throw AgentServiceError.invalidReply }
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        payload = try container.decode(Data.self)
        guard payload.count <= 16_777_216 else { throw AgentServiceError.invalidReply }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload)
    }
    func decode<T: Decodable>(_ type: T.Type, limit: Int = 16_777_216) throws -> T {
        guard payload.count <= limit else { throw AgentServiceError.invalidReply }
        return try JSONDecoder().decode(type, from: payload)
    }
    var customMirror: Mirror { Mirror(self, children: [:]) }
}
