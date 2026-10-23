import BackupDomain
import Foundation
import LocalAuthentication
import Security
import Synchronization
import Testing

@testable import Secrets

struct KeychainStoreTests {
    @Test func referenceIsStableCodableIdentityWithoutCredential() throws {
        let reference = SecretRef()
        #expect(try JSONDecoder().decode(SecretRef.self, from: JSONEncoder().encode(reference)) == reference)
        #expect(reference != SecretRef())
    }

    @Test func valuesAreBoundedAndRedacted() throws {
        let marker = UUID().uuidString
        let value = try SecretValue(data: Data(marker.utf8))
        #expect(value.data == Data(marker.utf8))
        #expect(!String(describing: value).contains(marker))
        #expect(!String(reflecting: value).contains(marker))
        #expect(Mirror(reflecting: value).children.isEmpty)
        #expect(throws: SecretStoreError.invalidValue) { try SecretValue(data: Data()) }
        #expect(throws: SecretStoreError.invalidValue) { try SecretValue(data: Data(count: 65_537)) }
        #expect(try SecretValue(data: Data(count: 65_536)).data.count == 65_536)
    }

    @Test func missingTeamNeverFallsBackToAnotherKeychain() throws {
        for identifier in ["", "com.example", "abcdef1234", "ABCDEFGHI", "ABCDEFGHIJK", "ABCD.12345", "ABCD\0EF123"] {
            #expect(throws: SecretStoreError.invalidConfiguration) { try KeychainStore(teamIdentifier: identifier) }
        }
    }

    @Test func securityQueryRestrictsEveryOperationToNonSynchronizedDataProtectionItem() {
        let item = KeychainItem(accessGroup: "TESTTEAM01.com.example.MacKopia.shared", account: UUID().uuidString)
        let query = SecurityKeychainBackend.query(item: item)
        #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(query[kSecAttrService as String] as? String == "com.example.MacKopia.secrets")
        #expect(query[kSecAttrAccessGroup as String] as? String == item.accessGroup)
        #expect(query[kSecAttrAccount as String] as? String == item.account)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(query[kSecValueData as String] == nil)
        let data = Data(UUID().uuidString.utf8)
        let attributes = SecurityKeychainBackend.attributes(value: data)
        #expect(attributes[kSecValueData as String] as? Data == data)
        #expect(
            attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                as String)
    }

    @Test func createUpdateReadAndDeleteKeepUUIDScope() async throws {
        let data = Data(UUID().uuidString.utf8)
        let backend = RecordingKeychain([
            .init(status: errSecItemNotFound), .init(status: errSecSuccess),
            .init(status: errSecSuccess), .init(status: errSecSuccess, data: data),
            .init(status: errSecSuccess), .init(status: errSecItemNotFound), .init(status: errSecItemNotFound),
        ])
        let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
        let reference = SecretRef()
        let value = try SecretValue(data: data)
        try await store.write(value, for: reference)
        try await store.write(value, for: reference)
        #expect(try await store.read(reference)?.data == data)
        try await store.delete(reference)
        try await store.delete(reference)
        #expect(try await store.read(reference) == nil)
        let calls = backend.calls
        #expect(calls.map(\.operation) == [.update, .add, .update, .read, .delete, .delete, .read])
        #expect(calls.allSatisfy { $0.item.account == reference.id.uuidString })
        #expect(calls.allSatisfy { $0.item.accessGroup == "TESTTEAM01.com.example.MacKopia.shared" })
        #expect(calls.prefix(3).allSatisfy { $0.value == data })
        #expect(calls.dropFirst(3).allSatisfy { $0.value == nil })
    }

    @Test func concurrentCreationRetriesUpdateWithoutDeletingExistingSecret() async throws {
        let backend = RecordingKeychain([
            .init(status: errSecItemNotFound), .init(status: errSecDuplicateItem), .init(status: errSecSuccess),
        ])
        let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
        try await store.write(SecretValue(data: Data(UUID().uuidString.utf8)), for: SecretRef())
        #expect(backend.calls.map(\.operation) == [.update, .add, .update])
    }

    @Test func failuresDoNotTriggerFallbackOrPublishRawStatus() async throws {
        for (status, expected) in [
            (errSecInteractionNotAllowed, SecretStoreError.unavailable), (errSecNotAvailable, .unavailable),
            (errSecAuthFailed, .accessDenied), (errSecMissingEntitlement, .accessDenied),
            (errSecUserCanceled, .accessDenied), (errSecDecode, .unexpectedResult),
        ] {
            for operation in [KeychainOperation.read, .update, .delete] {
                let backend = RecordingKeychain([.init(status: status)])
                let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
                let reference = SecretRef()
                await #expect(throws: expected) {
                    switch operation {
                    case .read: _ = try await store.read(reference)
                    case .update: try await store.write(SecretValue(data: Data([1])), for: reference)
                    case .delete: try await store.delete(reference)
                    case .add: Issue.record("Unexpected test operation")
                    }
                }
                #expect(backend.calls.count == 1)
            }
        }
    }

    @Test func malformedStoredValuesAreNotTreatedAsMissing() async throws {
        for data in [nil, Data(), Data(count: 65_537)] {
            let backend = RecordingKeychain([.init(status: errSecSuccess, data: data)])
            let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
            await #expect(throws: SecretStoreError.unexpectedResult) { try await store.read(SecretRef()) }
        }
    }

    @Test func failedCreationAndRepeatedRaceStopWithoutDeletingData() async throws {
        for results in [
            [errSecItemNotFound, errSecAuthFailed],
            [errSecItemNotFound, errSecDuplicateItem, errSecAuthFailed],
        ] {
            let backend = RecordingKeychain(results.map { KeychainResult(status: $0) })
            let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
            await #expect(throws: SecretStoreError.accessDenied) {
                try await store.write(SecretValue(data: Data([1])), for: SecretRef())
            }
            #expect(backend.calls.count == results.count)
            #expect(!backend.calls.contains { $0.operation == .delete })
        }
    }

    @Test func cancellationDoesNotReadWriteOrDelete() async throws {
        let backend = RecordingKeychain([])
        let store = try KeychainStore(teamIdentifier: "TESTTEAM01", backend: backend)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await store.read(SecretRef()) }
            await #expect(throws: CancellationError.self) {
                try await store.write(SecretValue(data: Data([1])), for: SecretRef())
            }
            await #expect(throws: CancellationError.self) { try await store.delete(SecretRef()) }
        }
        await task.value
        #expect(backend.calls.isEmpty)
    }
}

private final class RecordingKeychain: KeychainBackend {
    struct Call: Sendable {
        let operation: KeychainOperation
        let item: KeychainItem
        let value: Data?
    }
    struct State: Sendable {
        var results: [KeychainResult]
        var calls: [Call] = []
    }
    private let state: Mutex<State>

    init(_ results: [KeychainResult]) { state = Mutex(State(results: results)) }
    var calls: [Call] { state.withLock { $0.calls } }

    func perform(_ operation: KeychainOperation, item: KeychainItem, value: Data?) -> KeychainResult {
        state.withLock {
            $0.calls.append(Call(operation: operation, item: item, value: value))
            guard !$0.results.isEmpty else { return KeychainResult(status: errSecParam) }
            return $0.results.removeFirst()
        }
    }
}
