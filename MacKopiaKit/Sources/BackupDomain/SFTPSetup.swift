import CryptoKit
import Foundation

/// One-way Keychain envelope. Public host key material must come from a trusted channel.
public struct SFTPSetup: Codable, Sendable, CustomReflectable {
    public let host: String
    public let port: Int
    public let username: String
    public let path: String
    public let hostKey: String
    public let hostKeyConfirmed: Bool
    public let privateKey: String
    public let passphrase: String
    public let backupPassword: String
    public let keyRef: SecretRef

    public init(
        host: String, port: Int, username: String, path: String, hostKey: String, hostKeyConfirmed: Bool,
        privateKey: String, passphrase: String = "", backupPassword: String, keyRef: SecretRef = SecretRef()
    ) throws {
        self.host = host; self.port = port; self.username = username; self.path = path
        self.hostKey = hostKey; self.hostKeyConfirmed = hostKeyConfirmed; self.privateKey = privateKey
        self.passphrase = passphrase; self.backupPassword = backupPassword; self.keyRef = keyRef
        try validate()
    }

    public static func fingerprint(hostKey: String) -> String? {
        let parts = hostKey.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2,
            ["ssh-rsa", "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"].contains(
                String(parts[0])),
            let bytes = Data(base64Encoded: String(parts[1])), bytes.count > 4, bytes.count <= 8192,
            bytes.base64EncodedString() == parts[1]
        else { return nil }
        let count = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard count == parts[0].utf8.count, bytes.count > count + 4,
            Data(bytes.dropFirst(4).prefix(count)) == Data(parts[0].utf8)
        else { return nil }
        return "SHA256:" + Data(SHA256.hash(data: bytes)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    public func identifies(_ kind: RepositoryKind) -> Bool {
        guard case .sftp(let host, let port, let user, let path, _, _) = kind else { return false }
        return self.host.lowercased() == host.lowercased() && self.port == port && username == user && self.path == path
    }

    public var kind: RepositoryKind {
        .sftp(
            host: host, port: port, user: username, path: path,
            knownHostsFingerprint: Self.fingerprint(hostKey: hostKey) ?? "",
            auth: .privateKey(secretRef: keyRef, passphraseRef: nil))
    }

    public func validate() throws {
        try kind.validate()
        guard hostKeyConfirmed, !host.contains(where: { ",!*[]|".contains($0) }), !host.hasPrefix("-"),
            [privateKey, backupPassword].allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 32_768 }),
            !passphrase.utf8.contains(0), passphrase.utf8.count <= 4096,
            let data = try? JSONEncoder().encode(self), data.count <= 60_000
        else { throw DomainValidationError.invalidRepository }
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
