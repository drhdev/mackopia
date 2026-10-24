import BackupDomain
import BackupEngine
import KopiaServer

/// Real transport/lifecycle, deterministic cancellation immediately after the server acknowledges upload.
struct CancelAfterUploadSessions: BackupSessionOpening {
    let base: FilesystemBackupSessions
    let observation: CancellationSessionObservation

    func open(repository: Repository, options: PlanOptions) async throws -> KopiaBackupSession {
        let session = try await base.open(repository: repository, options: options)
        return KopiaBackupSession(service: CancelAfterUploadService(base: session.service, observation: observation)) {
            try await session.close()
            await observation.didClose()
        }
    }
}

actor CancellationSessionObservation {
    private(set) var closed = false
    private(set) var uploads = 0
    private(set) var cancellations = 0
    func didClose() { closed = true }
    func didUpload() { uploads += 1 }
    func didCancel() { cancellations += 1 }
}

private struct CancelAfterUploadService: KopiaBackupServing {
    let base: any KopiaBackupServing
    let observation: CancellationSessionObservation
    func repositoryStatus() async throws -> KopiaRepositoryStatus { try await base.repositoryStatus() }
    func sources() async throws -> KopiaSources { try await base.sources() }
    func snapshotManifests(source: KopiaSnapshotSource) async throws -> KopiaSnapshots {
        try await base.snapshotManifests(source: source)
    }
    func startUpload(source: KopiaSnapshotSource) async throws {
        try await base.startUpload(source: source)
        await observation.didUpload()
        withUnsafeCurrentTask { $0?.cancel() }
    }
    func cancelUpload(source: KopiaSnapshotSource) async throws {
        try await base.cancelUpload(source: source)
        await observation.didCancel()
    }
    func policyDefinition(source: KopiaSnapshotSource) async throws -> KopiaSourcePolicyDefinition? {
        try await base.policyDefinition(source: source)
    }
    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) async throws -> KopiaPolicyDocument {
        try await base.previewPolicy(source: source, updates: updates)
    }
    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) async throws {
        try await base.replacePolicy(source: source, document: document)
    }
}
