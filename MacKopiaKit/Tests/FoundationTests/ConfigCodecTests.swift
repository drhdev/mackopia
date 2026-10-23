import BackupDomain
import Foundation
import Testing

@testable import Persistence

struct ConfigCodecTests {
    @Test func v1RoundTripsOnlyMetadataAndReferences() throws {
        let repository = try Repository(
            name: "Test", kind: .filesystem(path: "/Test", volume: nil),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test"), secretRef: SecretRef())
        let configuration = try BackupConfiguration(repositories: [repository])
        let codec = try ConfigCodec()
        let data = try codec.encode(configuration)
        #expect(try codec.decode(data) == configuration)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "configuration"])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(!String(reflecting: configuration).contains(repository.identity.overrideHost))
        #expect(throws: DomainValidationError.invalidPlan) {
            try BackupConfiguration(repositories: [repository, repository])
        }
    }

    @Test func corruptFutureUnversionedAndOversizedDocumentsFailClosed() throws {
        let codec = try ConfigCodec()
        for data in [
            Data(), Data("{".utf8), Data("{}".utf8),
            Data(#"{"schemaVersion":1,"configuration":{"repositories":[],"plans":[{}]}}"#.utf8),
            Data(repeating: 32, count: ConfigCodec.maximumBytes + 1),
        ] {
            #expect(throws: ConfigStoreError.invalidConfiguration) { try codec.decode(data) }
        }
        for version in [0, -1, 2, Int.max] {
            let data = Data("{\"schemaVersion\":\(version)}".utf8)
            #expect(throws: ConfigStoreError.unsupportedVersion) { try codec.decode(data) }
        }
    }

    @Test func migrationsRunInVersionOrderAndValidateEveryStep() throws {
        // Synthetic future schemas exercise the pipeline; production currently supports schema 1 only.
        func step(_ version: Int) -> ConfigMigration {
            ConfigMigration(fromVersion: version) { data in
                var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(json["schemaVersion"] as? Int == version)
                json["schemaVersion"] = version + 1
                return try JSONSerialization.data(withJSONObject: json)
            }
        }
        let config = try BackupConfiguration()
        let original = try ConfigCodec().encode(config)
        let codec = try ConfigCodec(currentVersion: 3, migrations: [step(2), step(1)])
        #expect(try codec.decode(original) == config)
        #expect(try codec.decode(codec.encode(config)) == config)
        #expect(throws: ConfigStoreError.unsupportedVersion) {
            try ConfigCodec(currentVersion: 3, migrations: [step(1)]).decode(original)
        }
        #expect(throws: ConfigStoreError.unsupportedVersion) {
            try ConfigCodec(currentVersion: 3, migrations: [step(1), step(1)])
        }
        let invalidTransforms: [@Sendable (Data) throws -> Data] = [
            { $0 }, { _ in Data(#"{"schemaVersion":3}"#.utf8) },
            { _ in Data(repeating: 32, count: ConfigCodec.maximumBytes + 1) },
            { _ in throw CocoaError(.fileReadCorruptFile) },
            { _ in Data(#"{"schemaVersion":2,"configuration":{"repositories":[],"plans":[{}]}}"#.utf8) },
        ]
        for transform in invalidTransforms {
            let invalid = try ConfigCodec(
                currentVersion: 2,
                migrations: [ConfigMigration(fromVersion: 1, transform: transform)])
            #expect(throws: ConfigStoreError.invalidConfiguration) { try invalid.decode(original) }
        }
    }
    @Test func cancelledMigrationPropagatesCancellationWithoutPublishingConfiguration() throws {
        let migration = ConfigMigration(fromVersion: 1) { _ in throw CancellationError() }
        let codec = try ConfigCodec(currentVersion: 2, migrations: [migration])
        let original = try ConfigCodec().encode(BackupConfiguration())
        #expect(throws: CancellationError.self) { try codec.decode(original) }
    }

}
