import Foundation

/// Configuration metadata only. Validation does not connect, confirm host keys or authorize file operations.
public enum RepositoryKind: Codable, Sendable, Hashable, CustomReflectable {
    case filesystem(path: String, volume: VolumeIdentity?)
    case sftp(host: String, port: Int, user: String, path: String, knownHostsFingerprint: String, auth: SFTPAuth)
    case webdav(url: URL)
    case s3(endpoint: String, bucket: String, prefix: String, region: String?, objectLock: Bool)

    public func validate() throws {
        let valid: Bool
        switch self {
        case .filesystem(let path, _):
            valid = DomainValidation.absolutePath(path)
        case .webdav(let url):
            valid = Self.endpoint(url.absoluteString)
        case .s3(let endpoint, let bucket, let prefix, let region, _):
            valid =
                Self.endpoint(endpoint) && DomainValidation.text(bucket, limit: 255)
                && !bucket.contains(where: { $0.isWhitespace || "/\\".contains($0) })
                && prefix.utf8.count <= 16_384 && !prefix.utf8.contains(0)
                && (region.map { DomainValidation.text($0, limit: 256) } ?? true)
        case .sftp(let host, let port, let user, let path, let fingerprint, _):
            valid =
                DomainValidation.text(host, limit: 1024)
                && !host.contains(where: { $0.isWhitespace || $0.isNewline || "/\\?#@".contains($0) })
                && (1...65_535).contains(port) && DomainValidation.text(user, limit: 1024)
                && DomainValidation.text(path, limit: 16_384) && Self.fingerprint(fingerprint)
        }
        guard valid else { throw DomainValidationError.invalidRepository }
    }

    private static func endpoint(_ value: String) -> Bool {
        guard value.utf8.count <= 16_384, !value.utf8.contains(0),
            let parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
            !host.utf8.contains(0), !parts.path.utf8.contains(0),
            parts.url != nil
        else { return false }
        // An overflowing explicit port is reported as nil by URLComponents.port; nil is not always "absent".
        if let range = parts.rangeOfPort {
            guard let text = parts.string, let port = Int(text[range]), (1...65_535).contains(port) else {
                return false
            }
        }
        return true
    }

    private static func fingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:") else { return false }
        let digest = String(value.dropFirst(7))
        guard digest.utf8.count == 43, let bytes = Data(base64Encoded: digest + "="), bytes.count == 32 else {
            return false
        }
        return String(bytes.base64EncodedString().dropLast()) == digest
    }

    private enum CodingKeys: String, CodingKey { case filesystem, sftp, webdav, s3 }
    private enum Fields: String, CodingKey {
        case path, volume, host, port, user, knownHostsFingerprint, auth, url, endpoint, bucket, prefix, region,
            objectLock
    }

    public func encode(to encoder: any Encoder) throws {
        // Enum cases can be constructed directly: never serialize an unvalidated URL or backend payload.
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .filesystem(let path, let volume):
            var fields = container.nestedContainer(keyedBy: Fields.self, forKey: .filesystem)
            try fields.encode(path, forKey: .path)
            try fields.encodeIfPresent(volume, forKey: .volume)
        case .webdav(let url):
            var fields = container.nestedContainer(keyedBy: Fields.self, forKey: .webdav)
            try fields.encode(url, forKey: .url)
        case .sftp(let host, let port, let user, let path, let fingerprint, let auth):
            var fields = container.nestedContainer(keyedBy: Fields.self, forKey: .sftp)
            try fields.encode(host, forKey: .host)
            try fields.encode(port, forKey: .port)
            try fields.encode(user, forKey: .user)
            try fields.encode(path, forKey: .path)
            try fields.encode(fingerprint, forKey: .knownHostsFingerprint)
            try fields.encode(auth, forKey: .auth)
        case .s3(let endpoint, let bucket, let prefix, let region, let objectLock):
            var fields = container.nestedContainer(keyedBy: Fields.self, forKey: .s3)
            try fields.encode(endpoint, forKey: .endpoint)
            try fields.encode(bucket, forKey: .bucket)
            try fields.encode(prefix, forKey: .prefix)
            try fields.encodeIfPresent(region, forKey: .region)
            try fields.encode(objectLock, forKey: .objectLock)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DomainValidationError.invalidRepository
        }
        let fields = try container.nestedContainer(keyedBy: Fields.self, forKey: key)
        switch key {
        case .filesystem:
            self = .filesystem(
                path: try fields.decode(String.self, forKey: .path),
                volume: try fields.decodeIfPresent(VolumeIdentity.self, forKey: .volume))
        case .webdav: self = .webdav(url: try fields.decode(URL.self, forKey: .url))
        case .sftp:
            self = .sftp(
                host: try fields.decode(String.self, forKey: .host), port: try fields.decode(Int.self, forKey: .port),
                user: try fields.decode(String.self, forKey: .user),
                path: try fields.decode(String.self, forKey: .path),
                knownHostsFingerprint: try fields.decode(String.self, forKey: .knownHostsFingerprint),
                auth: try fields.decode(SFTPAuth.self, forKey: .auth))
        case .s3:
            self = .s3(
                endpoint: try fields.decode(String.self, forKey: .endpoint),
                bucket: try fields.decode(String.self, forKey: .bucket),
                prefix: try fields.decode(String.self, forKey: .prefix),
                region: try fields.decodeIfPresent(String.self, forKey: .region),
                objectLock: try fields.decode(Bool.self, forKey: .objectLock))
        }
        try validate()
    }

    public var customMirror: Mirror { Mirror(self, children: ["backend": "<private>"]) }
}
