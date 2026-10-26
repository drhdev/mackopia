import Foundation

/// One-way setup envelope; the agent stores this only in its Keychain item.
public struct WebDAVSetup: Codable, Sendable, CustomReflectable {
    public let url: URL
    public let username: String
    public let password: String
    public let backupPassword: String

    public init(url: URL, username: String, password: String, backupPassword: String) throws {
        self.url = url; self.username = username; self.password = password; self.backupPassword = backupPassword
        try validate()
    }

    public var kind: RepositoryKind { .webdav(url: url) }

    public func validate() throws {
        try kind.validate()
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme == "https" || (parts.scheme == "http" && parts.host == "127.0.0.1"),
            [username, password, backupPassword].allSatisfy({
                !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 16_384
            }), !username.contains(":"),
            let data = try? JSONEncoder().encode(self), data.count <= 60_000
        else { throw DomainValidationError.invalidRepository }
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
