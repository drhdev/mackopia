import Foundation
import LocalAuthentication
import Security

struct KeychainItem: Sendable {
    let accessGroup: String?
    let account: String
    static let service = "com.example.MacKopia.secrets"
}

enum KeychainOperation: Sendable { case read, add, update, delete }

struct KeychainResult: Sendable {
    let status: OSStatus
    var data: Data?
}

protocol KeychainBackend: Sendable {
    func perform(_ operation: KeychainOperation, item: KeychainItem, value: Data?) -> KeychainResult
}

/// The synchronous Security calls execute inside the store actor, never in a SwiftUI view.
struct SecurityKeychainBackend: KeychainBackend {
    func perform(_ operation: KeychainOperation, item: KeychainItem, value: Data?) -> KeychainResult {
        var query = Self.query(item: item)
        let status: OSStatus
        switch operation {
        case .read:
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            status = SecItemCopyMatching(query as CFDictionary, &result)
            return KeychainResult(status: status, data: result as? Data)
        case .add:
            guard let value else { return KeychainResult(status: errSecParam) }
            query.merge(Self.attributes(value: value, dataProtection: item.accessGroup != nil)) { _, new in new }
            status = SecItemAdd(query as CFDictionary, nil)
        case .update:
            guard let value else { return KeychainResult(status: errSecParam) }
            status = SecItemUpdate(
                query as CFDictionary,
                Self.attributes(value: value, dataProtection: item.accessGroup != nil) as CFDictionary)
        case .delete:
            status = SecItemDelete(query as CFDictionary)
        }
        return KeychainResult(status: status)
    }

    static func query(item: KeychainItem) -> [String: Any] {
        // Background work reports unavailability rather than presenting authentication dialogs.
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainItem.service,
            kSecAttrAccount as String: item.account,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context,
        ]
        if let group = item.accessGroup {
            query[kSecAttrAccessGroup as String] = group
            query[kSecUseDataProtectionKeychain as String] = true
        }
        // Without Data Protection/access-group attributes, SecItemAdd uses the login Keychain
        // and its default ACL trusts the creating application. Never supply an all-applications ACL.
        return query
    }

    static func attributes(value: Data, dataProtection: Bool = true) -> [String: Any] {
        var attributes: [String: Any] = [kSecValueData as String: value]
        if dataProtection {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attributes
    }
}
