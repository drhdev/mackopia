import AgentProtocol
import BackupDomain
import CryptoKit
import Foundation
import Testing

@testable import KopiaCLI

struct SFTPContractTests {
    private var publicKey: String {
        let algorithm = Data("ssh-ed25519".utf8)
        let blob = Data([0, 0, 0, 11]) + algorithm + Data([0, 0, 0, 32]) + Data(repeating: 7, count: 32)
        return "ssh-ed25519 " + blob.base64EncodedString()
    }
    private func setup(host: String = "example.invalid", key: String? = nil, confirmed: Bool = true) throws -> SFTPSetup
    {
        try SFTPSetup(
            host: host, port: 22, username: "backup", path: "/backups", hostKey: key ?? publicKey,
            hostKeyConfirmed: confirmed, privateKey: "private-key-canary", backupPassword: "backup-password-canary")
    }
    @Test func explicitTrustAndBoundedEnvelope() throws {
        #expect(throws: DomainValidationError.self) { try setup(confirmed: false) }
        for host in ["*.invalid", "a,b", "[example]", "!host", "-host", "a\nb"] {
            #expect(throws: DomainValidationError.self) { try setup(host: host) }
        }
        #expect(SFTPSetup.fingerprint(hostKey: publicKey + " comment") == nil)
        #expect(SFTPSetup.fingerprint(hostKey: "ssh-rsa " + publicKey.split(separator: " ")[1]) == nil)
        let value = try setup()
        #expect(!String(reflecting: value).contains(value.privateKey))
        let request = AgentRequest(
            .setupSFTP(
                name: "Example",
                source: try BackupSource(
                    path: "/tmp/source",
                    volume: VolumeIdentity(
                        uuid: "11111111-1111-1111-1111-111111111111", name: "Temporary", isRemovable: false,
                        isNetwork: false)), setup: value, create: true))
        try request.validate()
        try JSONDecoder().decode(AgentRequest.self, from: JSONEncoder().encode(request)).validate()
        var document = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        document["hostKeyConfirmed"] = false
        let untrusted = try JSONDecoder().decode(SFTPSetup.self, from: JSONSerialization.data(withJSONObject: document))
        #expect(throws: DomainValidationError.self) {
            try AgentRequest(.updateSFTPCredentials(repositoryID: UUID(), setup: untrusted)).validate()
        }
        let metadata = try JSONEncoder().encode(value.kind)
        #expect(metadata.range(of: Data(value.privateKey.utf8)) == nil)
        #expect(metadata.range(of: Data(value.backupPassword.utf8)) == nil)
    }
    @Test func trustRecordCannotBeReplacedOrFollowSymlink() throws {
        let root = try KopiaProcessTests().temporaryRoot().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let value = try setup()
        try KopiaSFTPTrust.install(setup: value, directory: root)
        try KopiaSFTPTrust.install(setup: value, directory: root)
        let file = root.appendingPathComponent("known_hosts")
        let original = try Data(contentsOf: file)
        try Data("changed".utf8).write(to: file)
        #expect(throws: (any Error).self) { try KopiaSFTPTrust.validate(setup: value, directory: root) }
        #expect(throws: (any Error).self) { try KopiaSFTPTrust.install(setup: value, directory: root) }
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target")
        try original.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try KopiaSFTPTrust.validate(setup: value, directory: root) }
    }
}
