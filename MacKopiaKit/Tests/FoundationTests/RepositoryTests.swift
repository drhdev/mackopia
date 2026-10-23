import BackupDomain
import Foundation
import Testing

struct RepositoryTests {
    private var fingerprint: String {
        "SHA256:" + String(Data(repeating: 7, count: 32).base64EncodedString().dropLast())
    }

    private func repository(_ kind: RepositoryKind, name: String = "Test destination") throws -> Repository {
        try Repository(
            name: name, kind: kind, identity: SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host"),
            secretRef: SecretRef())
    }

    @Test func allBackendKindsRoundTripWithStableIdentityAndReferences() throws {
        let url = try #require(URL(string: "https://example.invalid/Backup%20Share"))
        let volume = try VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: true, isNetwork: false)
        let auth = SFTPAuth.privateKey(secretRef: SecretRef(), passphraseRef: SecretRef())
        let kinds: [RepositoryKind] = [
            .filesystem(path: "/Volumes/Test/Backup ü %2F", volume: volume), .filesystem(path: "/Test", volume: nil),
            .webdav(url: url),
            .s3(
                endpoint: "https://example.invalid:9000", bucket: "test-bucket", prefix: "Backups/ü + %2F/",
                region: nil, objectLock: true),
            .sftp(
                host: "example.invalid", port: 22, user: "test-user", path: "relative/backup",
                knownHostsFingerprint: fingerprint, auth: auth),
            .sftp(
                host: "::1", port: 65_535, user: "test-user", path: "/backup", knownHostsFingerprint: fingerprint,
                auth: .password(secretRef: SecretRef())),
        ]
        for kind in kinds {
            let original = try repository(kind)
            #expect(try JSONDecoder().decode(Repository.self, from: JSONEncoder().encode(original)) == original)
        }
    }

    @Test func invalidEndpointsCannotEnterRepositoryOrJSON() throws {
        let marker = UUID().uuidString
        for (index, endpoint) in [
            "relative", "file:///Test", "https:///", "https://example.invalid:0", "https://example.invalid:65536",
            "https://example.invalid:999999999999999999999999", "https://example.invalid?token=" + marker,
            "https://example.invalid#fragment", "https://user:" + marker + "@example.invalid",
            "https://user@example.invalid", "https://example.invalid/%00",
        ].enumerated() {
            let kind = RepositoryKind.s3(endpoint: endpoint, bucket: "test", prefix: "", region: nil, objectLock: false)
            #expect(throws: DomainValidationError.invalidRepository, "Endpoint case \(index)") { try repository(kind) }
            #expect(throws: DomainValidationError.invalidRepository) { try JSONEncoder().encode(kind) }
            if let url = URL(string: endpoint) {
                #expect(throws: DomainValidationError.invalidRepository) { try repository(.webdav(url: url)) }
                #expect(throws: DomainValidationError.invalidRepository) {
                    try JSONEncoder().encode(RepositoryKind.webdav(url: url))
                }
            }
        }
    }

    @Test func filesystemAndS3FieldsHaveExplicitBounds() throws {
        for path in ["relative", "/Test/../Backup", "/Test\0Backup"] {
            #expect(throws: DomainValidationError.invalidRepository) {
                try repository(.filesystem(path: path, volume: nil))
            }
        }
        for (bucket, prefix, region) in [
            ("", "", nil), ("test/bucket", "", nil), ("test bucket", "", nil),
            ("test", "prefix\0", nil), ("test", String(repeating: "x", count: 16_385), nil),
            ("test", "", ""), ("test", "", String(repeating: "x", count: 257)),
        ] {
            #expect(throws: DomainValidationError.invalidRepository) {
                try repository(
                    .s3(
                        endpoint: "http://127.0.0.1:9000", bucket: bucket, prefix: prefix, region: region,
                        objectLock: false))
            }
        }
    }

    @Test func sftpRequiresBoundedIdentityPortAndSHA256Fingerprint() throws {
        let auth = SFTPAuth.password(secretRef: SecretRef())
        for (host, port, user, path, pin) in [
            ("", 22, "test", "backup", fingerprint),
            ("user@host", 22, "test", "backup", fingerprint), ("host/path", 22, "test", "backup", fingerprint),
            ("host", 0, "test", "backup", fingerprint), ("host", 65_536, "test", "backup", fingerprint),
            ("host", 22, "", "backup", fingerprint), ("host", 22, "test", "", fingerprint),
            ("host", 22, "test", "backup\0", fingerprint), ("host", 22, "test", "backup", ""),
            ("host", 22, "test", "backup", "SHA256:invalid"),
        ] {
            #expect(throws: DomainValidationError.invalidRepository) {
                try repository(
                    .sftp(host: host, port: port, user: user, path: path, knownHostsFingerprint: pin, auth: auth))
            }
        }
    }

    @Test func decodingCannotBypassBackendOrRepositoryValidation() throws {
        for json in [
            #"{"webdav":{"url":"https://example.invalid?credential=discard"}}"#,
            #"{"filesystem":{"path":"relative"}}"#,
            #"{"filesystem":{"path":"/Test"},"webdav":{"url":"https://example.invalid"}}"#,
            #"{"unknownBackend":{}}"#,
        ] {
            #expect(throws: DomainValidationError.invalidRepository) {
                try JSONDecoder().decode(RepositoryKind.self, from: Data(json.utf8))
            }
        }
        let original = try repository(.filesystem(path: "/Test", volume: nil))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["name"] = ""
        let invalid = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DomainValidationError.invalidRepository) {
            try JSONDecoder().decode(Repository.self, from: invalid)
        }
        object["name"] = original.name
        object["futureField"] = true
        #expect(
            try JSONDecoder().decode(Repository.self, from: JSONSerialization.data(withJSONObject: object)) == original)
        for name in ["", " \n", "Test\0Destination", String(repeating: "x", count: 1025)] {
            #expect(throws: DomainValidationError.invalidRepository) { try repository(original.kind, name: name) }
        }
        #expect(throws: DomainValidationError.invalidRepository) {
            try Repository(
                name: original.name, kind: original.kind, createdAt: Date(timeIntervalSince1970: .infinity),
                identity: original.identity, secretRef: original.secretRef)
        }
    }

    @Test func privateMetadataIsRedactedAndSFTPAuthContainsOnlyReferences() throws {
        let marker = UUID().uuidString
        let original = try repository(.filesystem(path: "/Test/" + marker, volume: nil), name: marker)
        #expect(!String(reflecting: original).contains(marker))
        #expect(!String(reflecting: original.kind).contains(marker))
        let reference = SecretRef()
        let data = try JSONEncoder().encode(SFTPAuth.privateKey(secretRef: reference, passphraseRef: nil))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let nested = try #require(object["privateKey"] as? [String: Any])
        #expect(Set(nested.keys) == ["secretRef"])
        #expect(
            try JSONDecoder().decode(SFTPAuth.self, from: data) == .privateKey(secretRef: reference, passphraseRef: nil)
        )
    }
}
