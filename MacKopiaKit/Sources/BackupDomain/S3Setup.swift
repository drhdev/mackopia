import Foundation

/// Accepted once over authenticated XPC and stored only in the agent's Keychain item.
public struct S3Setup: Codable, Sendable, CustomReflectable {
    public let endpoint: String
    public let bucket: String
    public let prefix: String
    public let region: String
    public let password: String
    public let accessKey: String
    public let secretKey: String
    public let sessionToken: String

    public init(
        endpoint: String, bucket: String, prefix: String, region: String, password: String,
        accessKey: String, secretKey: String, sessionToken: String = ""
    ) throws {
        self.endpoint = endpoint; self.bucket = bucket; self.prefix = prefix; self.region = region
        self.password = password; self.accessKey = accessKey; self.secretKey = secretKey;
        self.sessionToken = sessionToken
        try validate()
    }

    public var kind: RepositoryKind {
        .s3(endpoint: endpoint, bucket: bucket, prefix: prefix, region: region, objectLock: false)
    }

    public func validate() throws {
        try kind.validate()
        guard let parts = URLComponents(string: endpoint),
            (parts.scheme == "https" || (parts.scheme == "http" && parts.host == "127.0.0.1")),
            parts.path.isEmpty || parts.path == "/",
            [password, accessKey, secretKey].allSatisfy({ !$0.isEmpty }),
            [password, accessKey, secretKey, sessionToken].allSatisfy({
                !$0.utf8.contains(0) && $0.utf8.count <= 16_384
            }),
            let data = try? JSONEncoder().encode(self), data.count <= 65_536
        else { throw DomainValidationError.invalidRepository }
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
