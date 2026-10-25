import BackupDomain
import Foundation
import KopiaCLI
import KopiaServer
import SystemIntegration

extension LocalBackupService {
    public func browse(repositoryID: UUID, snapshotID: String?, components: [String]) async throws {
        try RestoreSelection.validate(snapshotID: snapshotID, components: components)
        try availableForMutation()
        guard restoreTask == nil else { throw LocalServiceIssue.busy }
        let value = try await withRestoreSession(repositoryID: repositoryID, destination: nil) { service in
            let browser = RestoreBrowser(service: service)
            var value = RestoreState(repositoryID: repositoryID)
            value.snapshots = try await browser.snapshots()
            value.snapshotID = snapshotID; value.components = components
            if let snapshotID {
                value.entries = try await browser.entries(snapshotID: snapshotID, components: components)
            }
            return value
        }
        restoreState = value; changed()
    }

    /// Admission returns immediately. The operation is owned by the service across XPC disconnects.
    public func restore(
        repositoryID: UUID, snapshotID: String, components: [String], destination: BackupSource, preview: Bool = false
    ) throws {
        try RestoreSelection.validate(snapshotID: snapshotID, components: components)
        try availableForMutation()
        guard active == nil, restoreTask == nil, destination.bookmark == nil else { throw LocalServiceIssue.busy }
        _ = try repository(repositoryID)
        let id = UUID()
        var state = RestoreState(repositoryID: repositoryID)
        state.preview = preview
        state.operationID = id; state.phase = .running; state.snapshotID = snapshotID; state.components = components
        restoreState = state
        restoreTask = Task {
            do {
                try await self.withRestoreSession(repositoryID: repositoryID, destination: destination) { service in
                    let object = try await RestoreBrowser(service: service).resolve(
                        snapshotID: snapshotID, components: components)
                    // A new private child isolates conflicts from existing user data. Kopia's overwrite switches remain off.
                    if preview {
                        guard !object.directory else { throw LocalServiceIssue.invalidRequest }
                        let parent = Array(components.dropLast())
                        let entries = try await RestoreBrowser(service: service).entries(
                            snapshotID: snapshotID, components: parent)
                        guard let file = entries.first(where: { $0.name == components.last }), file.bytes <= 50_000_000
                        else {
                            throw LocalServiceIssue.invalidRequest
                        }
                    }
                    let output = try RestoreDestination.create(
                        parent: destination, repository: try await self.repository(repositoryID)
                    )
                    .deletingLastPathComponent().appendingPathComponent(components.last ?? "Restore")
                    await self.restoreOutput(output.path)
                    let assertion = try LocalSleepPreventer().acquire()
                    defer { assertion.release() }
                    // Kopia 0.23.1: manifest/path preserves entry names and metadata; a raw file object lacks both.
                    let selector = object.selector
                    let task = try await service.startRestore(root: selector, destination: output.path)
                    guard let taskID = task.id else { throw LocalServiceIssue.invalidRequest }
                    do {
                        while true {
                            try Task.checkCancellation()
                            let status = try await service.task(id: taskID)
                            await self.restoreProgress(
                                bytes: status.counters?["Restored Bytes"]?.value ?? 0,
                                files: status.counters?["Restored Files"]?.value ?? 0)
                            if status.status == "SUCCESS" {
                                guard status.counters?["Ignored Errors"]?.value == 0,
                                    status.counters?["Skipped Files"]?.value == 0
                                else {
                                    throw LocalServiceIssue.backupFailed
                                }
                                break
                            }
                            guard status.status == "RUNNING" || status.status == "PENDING" else {
                                throw LocalServiceIssue.backupFailed
                            }
                            try await self.clock.sleep(for: .milliseconds(250))
                        }
                    } catch {
                        // Cancellation cannot release the reservation until the server is stopped and reaped below.
                        try? await Task.detached { try await service.cancelTask(id: taskID) }.value
                        throw error
                    }
                }
                self.restoreState?.phase = .succeeded
            } catch {
                self.restoreState?.phase = Task.isCancelled || error is CancellationError ? .cancelled : .failed
            }
            self.restoreTask = nil; self.changed()
        }
        changed()
    }

    public func cancelRestore(_ id: UUID) async throws {
        guard restoreState?.operationID == id, let task = restoreTask else { throw LocalServiceIssue.invalidRequest }
        task.cancel()
        await task.value
    }

    private func repository(_ id: UUID) throws -> Repository {
        guard let value = configuration?.repositories.first(where: { $0.id == id }) else {
            throw LocalServiceIssue.invalidRequest
        }
        return value
    }

    private func restoreOutput(_ path: String) { restoreState?.destination = path; changed() }
    private func restoreProgress(bytes: Int64, files: Int64) {
        restoreState?.bytes = bytes; restoreState?.files = files; changed()
    }

    func withRestoreSession<Value: Sendable>(
        repositoryID: UUID, destination: BackupSource?,
        operation: @escaping @Sendable (any KopiaRestoreServing) async throws -> Value
    ) async throws -> Value {
        guard !mutating, !stopped, let runtime else { throw LocalServiceIssue.busy }
        let repository = try repository(repositoryID)
        guard let configuration else { throw LocalServiceIssue.safeMode }
        mutating = true
        defer { mutating = false; changed() }
        let box = RestoreResult<Value>()
        do {
            try await runtime.withRepositoryAccess {
                let value = try await self.gate.withOperation(repositoryID: repositoryID) {
                    guard try await self.store.currentConfiguration() == configuration else {
                        throw LocalServiceIssue.safeMode
                    }
                    if let destination {
                        for candidate in configuration.repositories {
                            if case .filesystem(let path, _) = candidate.kind,
                                destination.path == path || destination.path.hasPrefix(path + "/")
                            {
                                throw LocalServiceIssue.destination
                            }
                        }
                        guard
                            try await FilesystemDestinationPreflight().validate(
                                path: destination.path, expectedVolume: destination.volume) != .insufficientSpace
                        else {
                            throw LocalServiceIssue.destination
                        }
                    }
                    return try await self.protection.withProtection(
                        sources: destination.map { [$0] } ?? [], repository: repository
                    ) {
                        let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: self.home)
                        try await KopiaBinaryVerifier(
                            executable: self.executable, paths: paths,
                            temporaryDirectory: self.temporary, expectedVersion: self.version
                        ).verify()
                        if case .filesystem(let path, let volume) = repository.kind {
                            guard let volume else { throw LocalServiceIssue.destination }
                            _ = try await FilesystemDestinationPreflight().validate(path: path, expectedVolume: volume)
                        }
                        let session = try await FilesystemBackupSessions(
                            executable: self.executable,
                            homeDirectory: self.home, temporaryDirectory: self.temporary, user: NSUserName(),
                            secrets: self.secrets
                        ).open(
                            repository: repository,
                            options: try PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false))
                        do {
                            guard let service = session.service as? any KopiaRestoreServing else {
                                throw LocalServiceIssue.unavailable
                            }
                            let result = try await operation(service)
                            try await session.close()
                            try Task.checkCancellation()
                            return result
                        } catch {
                            try? await session.close()
                            throw error
                        }
                    }
                }
                await box.set(value)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let issue = error as? LocalServiceIssue { throw issue }
            if error is RepositoryOperationError { throw LocalServiceIssue.busy }
            throw LocalServiceIssue.destination
        }
        guard let value = await box.value else { throw LocalServiceIssue.unavailable }
        return value
    }
}

private actor RestoreResult<Value: Sendable> {
    var value: Value?
    func set(_ value: Value) { self.value = value }
}

extension AutomaticBackupRuntime {
    /// Reserve external repository work without reloading configuration or probing original sources.
    func withRepositoryAccess(_ operation: @Sendable () async throws -> Void) async throws {
        if state != .running {
            try await operation()
            return
        }
        try await control(planID: nil) {
            guard await self.queue.activeJobs.isEmpty else { throw LocalServiceIssue.busy }
            try await operation()
        }
    }
}
