import BackupDomain
import Foundation
import Security

package actor KeychainStore: SecretStore {
    private let accessGroup: String?
    private let backend: any KeychainBackend

    /// Agent-only login Keychain path for locally signed distributions without a team or entitlement.
    package init() { accessGroup = nil; backend = SecurityKeychainBackend() }

    init(backend: any KeychainBackend) { accessGroup = nil; self.backend = backend }

    package init(teamIdentifier: String) throws {
        try self.init(teamIdentifier: teamIdentifier, backend: SecurityKeychainBackend())
    }

    init(teamIdentifier: String, backend: any KeychainBackend) throws {
        guard teamIdentifier.utf8.count == 10,
            teamIdentifier.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) })
        else { throw SecretStoreError.invalidConfiguration }
        accessGroup = teamIdentifier + ".com.example.MacKopia.shared"
        self.backend = backend
    }

    package func read(_ reference: SecretRef) async throws -> SecretValue? {
        try Task.checkCancellation()
        let result = backend.perform(.read, item: item(reference), value: nil)
        if result.status == errSecItemNotFound { return nil }
        try Self.check(result.status)
        guard let data = result.data, !data.isEmpty, data.count <= 65_536 else {
            throw SecretStoreError.unexpectedResult
        }
        return try SecretValue(data: data)
    }

    package func write(_ value: SecretValue, for reference: SecretRef) async throws {
        try Task.checkCancellation()
        let item = item(reference)
        var result = backend.perform(.update, item: item, value: value.data)
        if result.status == errSecItemNotFound {
            result = backend.perform(.add, item: item, value: value.data)
            // Another cooperating process may have created the item after our first update.
            if result.status == errSecDuplicateItem {
                result = backend.perform(.update, item: item, value: value.data)
            }
        }
        try Self.check(result.status)
    }

    package func delete(_ reference: SecretRef) async throws {
        try Task.checkCancellation()
        let result = backend.perform(.delete, item: item(reference), value: nil)
        if result.status != errSecItemNotFound { try Self.check(result.status) }
    }

    private func item(_ reference: SecretRef) -> KeychainItem {
        KeychainItem(accessGroup: accessGroup, account: reference.id.uuidString)
    }

    private static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecInteractionNotAllowed, errSecNotAvailable: throw SecretStoreError.unavailable
        case errSecAuthFailed, errSecMissingEntitlement, errSecUserCanceled: throw SecretStoreError.accessDenied
        default: throw SecretStoreError.unexpectedResult
        }
    }
}
