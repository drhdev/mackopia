import BackupDomain
import Foundation

struct ConfigMigration: Sendable {
    let fromVersion: Int
    let transform: @Sendable (Data) throws -> Data
}

struct ConfigCodec: Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    let currentVersion: Int
    let migrations: [ConfigMigration]

    init(currentVersion: Int = 1, migrations: [ConfigMigration] = []) throws {
        guard currentVersion > 0, Set(migrations.map(\.fromVersion)).count == migrations.count,
            migrations.allSatisfy({ $0.fromVersion > 0 && $0.fromVersion < currentVersion })
        else { throw ConfigStoreError.unsupportedVersion }
        self.currentVersion = currentVersion
        self.migrations = migrations
    }

    func decode(_ bytes: Data) throws -> BackupConfiguration {
        do {
            var data = bytes
            var version = try header(data)
            guard version > 0, version <= currentVersion else { throw ConfigStoreError.unsupportedVersion }
            while version < currentVersion {
                try Task.checkCancellation()
                guard let migration = migrations.first(where: { $0.fromVersion == version }) else {
                    throw ConfigStoreError.unsupportedVersion
                }
                data = try migration.transform(data)
                guard try header(data) == version + 1 else { throw ConfigStoreError.invalidConfiguration }
                version += 1
            }
            return try JSONDecoder().decode(Envelope.self, from: data).configuration
        } catch is CancellationError { throw CancellationError() } catch let error as ConfigStoreError {
            throw error
        } catch { throw ConfigStoreError.invalidConfiguration }
    }

    func encode(_ configuration: BackupConfiguration) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: currentVersion, configuration: configuration))
            guard data.count <= Self.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
            return data
        } catch { throw ConfigStoreError.invalidConfiguration }
    }

    private func header(_ data: Data) throws -> Int {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw ConfigStoreError.invalidConfiguration }
        struct Header: Decodable { let schemaVersion: Int }
        return try JSONDecoder().decode(Header.self, from: data).schemaVersion
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let configuration: BackupConfiguration
    }
}
