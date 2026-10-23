import Foundation

public struct BackupSource: Identifiable, Codable, Sendable, Hashable, CustomReflectable {
    public let id: UUID
    public let path: String
    public let volume: VolumeIdentity
    public let bookmark: Data?

    public init(id: UUID = UUID(), path: String, volume: VolumeIdentity, bookmark: Data? = nil) throws {
        guard DomainValidation.absolutePath(path) else { throw DomainValidationError.invalidPath }
        if let bookmark, bookmark.isEmpty || bookmark.count > 1_048_576 {
            throw DomainValidationError.invalidSource
        }
        self.id = id
        self.path = path
        self.volume = volume
        self.bookmark = bookmark
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id), path: container.decode(String.self, forKey: .path),
            volume: container.decode(VolumeIdentity.self, forKey: .volume),
            bookmark: container.decodeIfPresent(Data.self, forKey: .bookmark))
    }

    public var customMirror: Mirror { Mirror(self, children: ["source": "<private>"]) }
}
