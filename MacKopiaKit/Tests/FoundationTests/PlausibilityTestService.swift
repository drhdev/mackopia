import BackupDomain
import BackupEngine
import Foundation
import KopiaServer

@testable import KopiaServer

actor PlausibilityTestService: KopiaBackupServing {
    enum Mode: Sendable { case success, rejected, lostResponse, wrongRoot, held }
    let base = ManualBackupService()
    let mode: Mode
    var pinRequests = 0
    private var pinned: Set<String> = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode = .success) { self.mode = mode }
    func releasePin() { continuation?.resume(); continuation = nil }
    func repositoryStatus() async throws -> KopiaRepositoryStatus { try await base.repositoryStatus() }
    func sources() async throws -> KopiaSources { try await base.sources() }
    func startUpload(source: KopiaSnapshotSource) async throws { try await base.startUpload(source: source) }
    func cancelUpload(source: KopiaSnapshotSource) async throws { try await base.cancelUpload(source: source) }
    func pinSnapshot(id: String) async throws -> KopiaSnapshot {
        pinRequests += 1
        if mode == .held { await withCheckedContinuation { continuation = $0 } }
        if mode == .rejected { throw BackupOperationError.operationFailed }
        pinned.insert(id)
        if mode == .lostResponse { throw BackupOperationError.operationFailed }
        return try snapshot(id: id, current: true, pinned: true)
    }
    func snapshotManifests(source: KopiaSnapshotSource) async throws -> KopiaSnapshots {
        var snapshots = [try snapshot(id: "old-" + source.path, current: false)]
        if await base.uploaded.contains(source.path) {
            let id = "snapshot-" + source.path
            snapshots.append(try snapshot(id: id, current: true, pinned: pinned.contains(id)))
        }
        return KopiaSnapshots(snapshots: snapshots, unfilteredCount: nil, uniqueCount: nil)
    }
    private func snapshot(id: String, current: Bool, pinned: Bool = false) throws -> KopiaSnapshot {
        let timestamp = current ? "2026-10-25T01:00:00Z" : "2026-10-24T01:00:00Z"
        let json: [String: Any] = [
            "id": pinned ? "pinned-" + id : id,
            "rootID": pinned && mode == .wrongRoot ? "foreign-root" : "root",
            "startTime": timestamp, "endTime": timestamp,
            "summary": ["files": current ? 3 : 100, "size": current ? 42 : 100, "numFailed": 0],
            "pins": pinned ? [KopiaServerClient.plausibilityPin] : [],
        ]
        return try JSONDecoder().decode(KopiaSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func policyDefinition(source: KopiaSnapshotSource) async -> KopiaSourcePolicyDefinition? {
        await base.policyDefinition(source: source)
    }
    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) async -> KopiaPolicyDocument {
        await base.previewPolicy(source: source, updates: updates)
    }
    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) async {
        await base.replacePolicy(source: source, document: document)
    }
}

struct PlausibilityTestSessions: BackupSessionOpening {
    let service: PlausibilityTestService
    func open(repository: Repository, options: PlanOptions) async -> KopiaBackupSession {
        await service.base.markOpened()
        return KopiaBackupSession(service: service) { try await service.base.close() }
    }
}
