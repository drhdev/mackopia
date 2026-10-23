import Foundation

/// Stable Kopia override identity, independent of changes to the current Mac's account or host name.
public struct SnapshotIdentity: Codable, Sendable, Hashable, CustomReflectable {
    public let overrideUser: String
    public let overrideHost: String

    public init(overrideUser: String, overrideHost: String) throws {
        guard DomainValidation.text(overrideUser, limit: 1024), DomainValidation.text(overrideHost, limit: 1024) else {
            throw DomainValidationError.invalidSnapshotIdentity
        }
        self.overrideUser = overrideUser
        self.overrideHost = overrideHost
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            overrideUser: container.decode(String.self, forKey: .overrideUser),
            overrideHost: container.decode(String.self, forKey: .overrideHost))
    }

    public var customMirror: Mirror { Mirror(self, children: ["identity": "<private>"]) }
}
