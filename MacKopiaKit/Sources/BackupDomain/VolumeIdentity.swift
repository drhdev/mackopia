import Foundation

/// A display name never grants permission to read from or write to a mounted volume.
public struct VolumeIdentity: Codable, Sendable, Hashable, CustomReflectable {
    public let uuid: String
    public let name: String
    public let isRemovable: Bool
    public let isNetwork: Bool
    public let remountURL: URL?

    public init(uuid: String, name: String, isRemovable: Bool, isNetwork: Bool, remountURL: URL? = nil) throws {
        guard let identifier = DomainValidation.volumeUUID(uuid), DomainValidation.text(name, limit: 1024) else {
            throw DomainValidationError.invalidVolumeIdentity
        }
        if let remountURL {
            guard isNetwork, let parts = URLComponents(url: remountURL, resolvingAgainstBaseURL: false),
                parts.scheme?.lowercased() == "smb", let host = parts.host, !host.isEmpty,
                parts.password == nil, parts.query == nil, parts.fragment == nil,
                !host.utf8.contains(0), !parts.path.utf8.contains(0), !(parts.user?.utf8.contains(0) ?? false),
                !remountURL.absoluteString.utf8.contains(0), remountURL.absoluteString.utf8.count <= 16_384
            else { throw DomainValidationError.invalidVolumeIdentity }
        }
        self.uuid = identifier.uuidString
        self.name = name
        self.isRemovable = isRemovable
        self.isNetwork = isNetwork
        self.remountURL = remountURL
    }

    /// Caller must obtain the current volume UUID from the actual path immediately before file operations.
    public func requireMatch(uuid observedUUID: String?) throws {
        guard let observedUUID, let observed = DomainValidation.volumeUUID(observedUUID) else {
            throw DomainValidationError.volumeUnavailable
        }
        guard observed.uuidString == uuid else { throw DomainValidationError.volumeMismatch }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            uuid: container.decode(String.self, forKey: .uuid), name: container.decode(String.self, forKey: .name),
            isRemovable: container.decode(Bool.self, forKey: .isRemovable),
            isNetwork: container.decode(Bool.self, forKey: .isNetwork),
            remountURL: container.decodeIfPresent(URL.self, forKey: .remountURL))
    }

    public var customMirror: Mirror { Mirror(self, children: ["volume": "<private>"]) }
}
