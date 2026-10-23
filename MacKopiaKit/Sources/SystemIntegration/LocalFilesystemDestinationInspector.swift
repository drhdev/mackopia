import BackupDomain
import Foundation

package actor LocalFilesystemDestinationInspector: FilesystemDestinationInspecting {
    package init() {}

    package func inspectDestination(at path: String) async throws -> FilesystemDestinationObservation {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { throw VolumeInspectionError.invalidPath }
        do {
            var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .volumeUUIDStringKey, .isWritableKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
            ])
            try Task.checkCancellation()
            guard values.isDirectory == true else { throw VolumeInspectionError.notDirectory }
            guard let uuid = values.volumeUUIDString, let writable = values.isWritable,
                let available = values.volumeAvailableCapacityForImportantUsage,
                let total = values.volumeTotalCapacity
            else { throw VolumeInspectionError.unavailable }
            return try FilesystemDestinationObservation(
                volumeUUID: uuid, isWritable: writable, availableBytes: available, totalBytes: Int64(total))
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? VolumeInspectionError { throw error }
            let error = error as NSError
            if (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileReadNoPermission.rawValue)
                || (error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code))
            {
                throw VolumeInspectionError.permissionDenied
            }
            throw VolumeInspectionError.unavailable
        }
    }
}
