import BackupDomain
import Foundation
import Testing

struct BackupSourceTests {
    private func volume(uuid: String = UUID().uuidString, name: String = "Test volume") throws -> VolumeIdentity {
        try VolumeIdentity(uuid: uuid, name: name, isRemovable: true, isNetwork: false)
    }

    @Test func roundTripPreservesSourceAndStableSnapshotIdentity() throws {
        let source = try BackupSource(
            path: "/Volumes/Test/Quelle ü + & ? # %2F", volume: volume(), bookmark: Data([1, 2, 3]))
        let identity = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host")
        #expect(try JSONDecoder().decode(BackupSource.self, from: JSONEncoder().encode(source)) == source)
        #expect(try JSONDecoder().decode(SnapshotIdentity.self, from: JSONEncoder().encode(identity)) == identity)
        #expect(try BackupSource(path: "/", volume: volume()).path == "/")
        #expect(
            try BackupSource(path: "/Test/e\u{301}", volume: volume()).path.utf8.elementsEqual("/Test/e\u{301}".utf8))
        let other = try BackupSource(path: source.path, volume: source.volume)
        #expect(other.id != source.id)
    }

    @Test func sameNameAndPathNeverReplaceVolumeUUIDMatch() throws {
        let uuid = UUID().uuidString
        let expected = try volume(uuid: uuid)
        try expected.requireMatch(uuid: uuid.lowercased())
        let replacement = try volume()
        #expect(expected.name == replacement.name)
        #expect(throws: DomainValidationError.volumeMismatch) { try expected.requireMatch(uuid: replacement.uuid) }
        for missing in [nil, "", "invalid", uuid + "\0"] {
            #expect(throws: DomainValidationError.volumeUnavailable) { try expected.requireMatch(uuid: missing) }
        }
        let renamed = try volume(uuid: uuid, name: "Renamed volume")
        try expected.requireMatch(uuid: renamed.uuid)
        #expect(try volume(uuid: uuid.lowercased()).uuid == uuid)
    }

    @Test func ambiguousAndUnboundedPathsAreRejectedWithoutNormalization() throws {
        let volume = try volume()
        for path in [
            "", "relative/path", "~/Documents", "//Test", "/Test/", "/Test//Source", "/Test/./Source",
            "/Test/../Source", "/Test\0Source", "/" + String(repeating: "x", count: 16_384),
        ] {
            #expect(throws: DomainValidationError.invalidPath) { try BackupSource(path: path, volume: volume) }
        }
        for path in ["/Test/100%", "/Test/a:b", "/Test/..hidden", "/" + String(repeating: "x", count: 16_383)] {
            #expect(try BackupSource(path: path, volume: volume).path == path)
        }
    }

    @Test func bookmarksAreBoundedAndNotRequired() throws {
        let volume = try volume()
        #expect(try BackupSource(path: "/Test", volume: volume).bookmark == nil)
        #expect(
            try BackupSource(path: "/Test", volume: volume, bookmark: Data(count: 1_048_576)).bookmark?.count
                == 1_048_576)
        for bookmark in [Data(), Data(count: 1_048_577)] {
            #expect(throws: DomainValidationError.invalidSource) {
                try BackupSource(path: "/Test", volume: volume, bookmark: bookmark)
            }
        }
    }

    @Test func remountURLsCannotPersistPasswordsOrOverrideTheNetworkDestination() throws {
        let uuid = UUID().uuidString
        let url = try #require(URL(string: "smb://test-server/Backup%20Share"))
        let identity = try VolumeIdentity(
            uuid: uuid, name: "Test", isRemovable: false, isNetwork: true, remountURL: url)
        #expect(try JSONDecoder().decode(VolumeIdentity.self, from: JSONEncoder().encode(identity)) == identity)
        for text in [
            "file:///Volumes/Test", "https://example.invalid/share", "smb:///share", "smb://host/share?x=y",
            "smb://host/share#fragment", "smb://host/share%00", "smb://user:" + UUID().uuidString + "@host/share",
        ] {
            let unsafe = try #require(URL(string: text))
            #expect(throws: DomainValidationError.invalidVolumeIdentity) {
                try VolumeIdentity(uuid: uuid, name: "Test", isRemovable: false, isNetwork: true, remountURL: unsafe)
            }
        }
        #expect(throws: DomainValidationError.invalidVolumeIdentity) {
            try VolumeIdentity(uuid: uuid, name: "Test", isRemovable: false, isNetwork: false, remountURL: url)
        }
    }

    @Test func snapshotIdentityRejectsIncompleteAndOversizedValues() throws {
        for invalid in ["", " \n", "test\0user", String(repeating: "ü", count: 513)] {
            #expect(throws: DomainValidationError.invalidSnapshotIdentity) {
                try SnapshotIdentity(overrideUser: invalid, overrideHost: "test-host")
            }
            #expect(throws: DomainValidationError.invalidSnapshotIdentity) {
                try SnapshotIdentity(overrideUser: "test-user", overrideHost: invalid)
            }
        }
    }

    @Test func decodingCannotBypassSourceOrNestedVolumeValidation() throws {
        let source = try BackupSource(path: "/Test/Source", volume: volume())
        let data = try JSONEncoder().encode(source)
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["path"] = "relative/path"
        let invalidPath = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DomainValidationError.invalidPath) {
            try JSONDecoder().decode(BackupSource.self, from: invalidPath)
        }
        object["path"] = source.path
        object["bookmark"] = Data(count: 1_048_577).base64EncodedString()
        let invalidBookmark = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DomainValidationError.invalidSource) {
            try JSONDecoder().decode(BackupSource.self, from: invalidBookmark)
        }
        object.removeValue(forKey: "bookmark")
        var nested = try #require(object["volume"] as? [String: Any])
        nested["uuid"] = "not-a-uuid"
        object["volume"] = nested
        let invalidVolume = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DomainValidationError.invalidVolumeIdentity) {
            try JSONDecoder().decode(BackupSource.self, from: invalidVolume)
        }
        object["volume"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source.volume))
        object["futureField"] = true
        #expect(
            try JSONDecoder().decode(BackupSource.self, from: JSONSerialization.data(withJSONObject: object)) == source)
        let invalidIdentity = Data(#"{"overrideUser":"","overrideHost":"test-host"}"#.utf8)
        #expect(throws: DomainValidationError.invalidSnapshotIdentity) {
            try JSONDecoder().decode(SnapshotIdentity.self, from: invalidIdentity)
        }
    }

    @Test func volumeRequiresUUIDAndNonemptyBoundedDisplayName() throws {
        for invalid in ["", "Test", UUID().uuidString + "\0"] {
            #expect(throws: DomainValidationError.invalidVolumeIdentity) { try volume(uuid: invalid) }
        }
        for invalid in ["", " \n", "Test\0Volume", String(repeating: "x", count: 1025)] {
            #expect(throws: DomainValidationError.invalidVolumeIdentity) { try volume(name: invalid) }
        }
    }

    @Test func reflectionDoesNotRevealNamesPathsBookmarksOrSnapshotIdentity() throws {
        let marker = UUID().uuidString
        let source = try BackupSource(
            path: "/Test/" + marker, volume: volume(name: marker), bookmark: Data(marker.utf8))
        let identity = try SnapshotIdentity(overrideUser: marker, overrideHost: marker)
        #expect(!String(reflecting: source).contains(marker))
        #expect(!String(reflecting: source.volume).contains(marker))
        #expect(!String(reflecting: identity).contains(marker))
    }
}
