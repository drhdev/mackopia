import BackupDomain
import SystemIntegration

package enum DestinationCapacityStatus: Sendable, Equatable {
    case sufficient, lowSpaceWarning, insufficientSpace
}

/// Does not create a probe file or open Kopia. Remote reachability is checked separately by the server.
package struct FilesystemDestinationPreflight: Sendable {
    private let inspector: any FilesystemDestinationInspecting

    package init(inspector: any FilesystemDestinationInspecting = LocalFilesystemDestinationInspector()) {
        self.inspector = inspector
    }

    package func validate(path: String, expectedVolume: VolumeIdentity) async throws -> DestinationCapacityStatus {
        try Task.checkCancellation()
        let observation: FilesystemDestinationObservation
        do {
            observation = try await inspector.inspectDestination(at: path)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if error as? VolumeInspectionError == .permissionDenied {
                throw BackupPreflightError.destinationPermissionDenied
            }
            throw BackupPreflightError.destinationUnavailable
        }
        guard observation.volumeUUID == expectedVolume.uuid else {
            throw BackupPreflightError.destinationVolumeMismatch
        }
        guard observation.isWritable else { throw BackupPreflightError.destinationPermissionDenied }
        return Self.capacityStatus(observation)
    }

    package static func capacityStatus(_ observation: FilesystemDestinationObservation) -> DestinationCapacityStatus {
        if observation.availableBytes < 1_000_000_000 { return .insufficientSpace }
        // Integer ceiling preserves the strict 5% threshold without multiplication overflow or rounding loss.
        let fivePercent = observation.totalBytes / 20 + (observation.totalBytes % 20 == 0 ? 0 : 1)
        if observation.availableBytes < 5_000_000_000 || observation.availableBytes < fivePercent {
            return .lowSpaceWarning
        }
        return .sufficient
    }
}
