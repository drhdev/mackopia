import Foundation

public struct Repository: Identifiable, Codable, Sendable, Hashable, CustomReflectable {
    public let id: UUID
    public let name: String
    public let kind: RepositoryKind
    public let createdAt: Date
    public let identity: SnapshotIdentity
    public let secretRef: SecretRef

    public init(
        id: UUID = UUID(), name: String, kind: RepositoryKind, createdAt: Date = Date(),
        identity: SnapshotIdentity, secretRef: SecretRef
    ) throws {
        guard DomainValidation.text(name, limit: 1024), createdAt.timeIntervalSince1970.isFinite else {
            throw DomainValidationError.invalidRepository
        }
        try kind.validate()
        self.id = id
        self.name = name
        self.kind = kind
        self.createdAt = createdAt
        self.identity = identity
        self.secretRef = secretRef
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id), name: container.decode(String.self, forKey: .name),
            kind: container.decode(RepositoryKind.self, forKey: .kind),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            identity: container.decode(SnapshotIdentity.self, forKey: .identity),
            secretRef: container.decode(SecretRef.self, forKey: .secretRef))
    }

    public var customMirror: Mirror { Mirror(self, children: ["destination": "<private>"]) }
}
