import BackupDomain
import BackupEngine
import Foundation
import KopiaCLI
import Secrets
import Testing

struct BackupPrerequisitePreflightTests {
    @Test func checksBinaryBeforeReadingOnlyBackupPasswordAndNeverWrites() async throws {
        let repository = try repository()
        let services = PrerequisiteServices(value: try SecretValue(data: Data(UUID().uuidString.utf8)))
        let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
        try await preflight.validate(repository: repository)
        #expect(await services.operations == ["binary", "read"])
        #expect(await services.references == [repository.secretRef])
        // No cached success: both prerequisites are observed afresh on every check.
        try await preflight.validate(repository: repository)
        #expect(await services.operations == ["binary", "read", "binary", "read"])
    }

    @Test func binaryFailureDoesNotTouchKeychainAndUnknownErrorsAreSanitized() async throws {
        let repository = try repository()
        for (error, expected) in [
            (KopiaBinaryVerificationError.unavailable as any Error, KopiaBinaryVerificationError.unavailable),
            (KopiaBinaryVerificationError.versionMismatch, .versionMismatch),
            (NSError(domain: "private-marker", code: 1), .probeFailed),
        ] {
            let services = PrerequisiteServices(binaryError: error)
            let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
            await #expect(throws: expected) { try await preflight.validate(repository: repository) }
            #expect(await services.operations == ["binary"])
        }
    }

    @Test func missingPasswordIsBlockingAndNeverCreatesFallbackCredentials() async throws {
        let repository = try repository()
        let services = PrerequisiteServices()
        let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
        await #expect(throws: BackupPreflightError.backupPasswordRequired) {
            try await preflight.validate(repository: repository)
        }
        #expect(await services.operations == ["binary", "read"])
        #expect(await services.references == [repository.secretRef])
    }

    @Test func keychainFailuresAreDistinctFromMissingPassword() async throws {
        let repository = try repository()
        for (error, expected) in [
            (SecretStoreError.accessDenied as any Error, SecretStoreError.accessDenied),
            (SecretStoreError.invalidConfiguration, .invalidConfiguration),
            (SecretStoreError.unavailable, .unavailable),
            (NSError(domain: "private-marker", code: 1), .unavailable),
        ] {
            let services = PrerequisiteServices(secretError: error)
            let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
            await #expect(throws: expected) { try await preflight.validate(repository: repository) }
            #expect(await services.operations == ["binary", "read"])
        }
    }

    @Test func cancellationAtEveryBoundaryRemainsCancellation() async throws {
        let repository = try repository()
        for services in [
            PrerequisiteServices(binaryError: CancellationError()),
            PrerequisiteServices(cancelOn: "binary"),
            PrerequisiteServices(binaryError: KopiaBinaryVerificationError.probeFailed, cancelOn: "binary"),
            PrerequisiteServices(secretError: CancellationError()),
            PrerequisiteServices(cancelOn: "read"),
            PrerequisiteServices(secretError: SecretStoreError.accessDenied, cancelOn: "read"),
            PrerequisiteServices(value: try SecretValue(data: Data([1])), cancelOn: "read"),
        ] {
            let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
            let task = Task<Void, Never> {
                await #expect(throws: CancellationError.self) { try await preflight.validate(repository: repository) }
            }
            await task.value
        }
        let services = PrerequisiteServices()
        let preflight = BackupPrerequisitePreflight(binary: services, secrets: services)
        let task = Task<Void, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) { try await preflight.validate(repository: repository) }
        }
        await task.value
        #expect(await services.operations.isEmpty)
    }

    private func repository() throws -> Repository {
        try Repository(
            name: "Test", kind: .filesystem(path: "/Test", volume: nil),
            identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test-host"), secretRef: SecretRef())
    }
}

private actor PrerequisiteServices: KopiaBinaryVerifying, SecretStore {
    let value: SecretValue?
    let binaryError: (any Error)?
    let secretError: (any Error)?
    let cancelOn: String?
    private(set) var operations: [String] = []
    private(set) var references: [SecretRef] = []

    init(
        value: SecretValue? = nil, binaryError: (any Error)? = nil, secretError: (any Error)? = nil,
        cancelOn: String? = nil
    ) {
        self.value = value
        self.binaryError = binaryError
        self.secretError = secretError
        self.cancelOn = cancelOn
    }

    func verify() async throws {
        record("binary")
        if let binaryError { throw binaryError }
    }

    func read(_ reference: SecretRef) async throws -> SecretValue? {
        record("read")
        references.append(reference)
        if let secretError { throw secretError }
        return value
    }

    func write(_ value: SecretValue, for reference: SecretRef) async throws { Issue.record("Preflight wrote a secret") }
    func delete(_ reference: SecretRef) async throws { Issue.record("Preflight deleted a secret") }

    private func record(_ operation: String) {
        operations.append(operation)
        if cancelOn == operation { withUnsafeCurrentTask { $0?.cancel() } }
    }
}
