import BackupDomain
import SystemIntegration

package struct LocalBackupOperationProtection: BackupOperationProtecting {
    private let monitor: any VolumeProtectionStarting

    package init(monitor: any VolumeProtectionStarting = LocalVolumeProtectionMonitor()) {
        self.monitor = monitor
    }

    package func withProtection<Result: Sendable>(
        sources: [BackupSource], repository: Repository,
        operation: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        var directories = try sources.map { try ProtectedDirectory(path: $0.path, volumeUUID: $0.volume.uuid) }
        if case .filesystem(let path, let volume) = repository.kind {
            guard let volume else { throw BackupOperationError.protectionUnavailable }
            directories.append(try ProtectedDirectory(path: path, volumeUUID: volume.uuid))
        }
        // Remote browsing has neither a destination volume nor an original source to monitor.
        // Restore writes still pass their output volume above; all operations retain the repo reservation.
        if directories.isEmpty, case .s3 = repository.kind {
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        do {
            let session = try await monitor.start(directories: directories)
            do {
                try await session.checkActive()
                let result = try await withThrowingTaskGroup(of: Result.self) { group in
                    group.addTask {
                        try await session.checkActive()
                        return try await operation()
                    }
                    group.addTask {
                        for await _ in session.events { throw BackupOperationError.volumeDisappeared }
                        try Task.checkCancellation()
                        // Unexpected termination of observation must not let the operation continue.
                        throw BackupOperationError.protectionUnavailable
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw BackupOperationError.protectionUnavailable }
                    return result
                }
                try await session.checkActive()
                await session.close()
                try Task.checkCancellation()
                return result
            } catch {
                // Task-group scope has already joined operation cleanup before monitoring is disarmed.
                await session.close()
                throw error
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? VolumeProtectionError {
                throw error == .volumeDisappeared
                    ? BackupOperationError.volumeDisappeared : BackupOperationError.protectionUnavailable
            }
            throw error
        }
    }
}
