import Foundation

/// Persistable identity of a Keychain item; contains no credential or destination name.
public struct SecretRef: Codable, Sendable, Hashable {
    public let id: UUID

    public init(id: UUID = UUID()) { self.id = id }
}
