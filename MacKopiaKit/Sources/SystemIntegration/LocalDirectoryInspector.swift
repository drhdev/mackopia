import BackupDomain
import Foundation

/// A fresh point-in-time observation of an existing directory, including its symlink target.
package actor LocalDirectoryInspector: DirectoryInspecting {
    package init() {}

    package func inspectDirectory(at path: String) async throws -> DirectoryObservation {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { throw VolumeInspectionError.invalidPath }
        do {
            var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .canonicalPathKey, .volumeUUIDStringKey, .volumeSupportsCaseSensitiveNamesKey,
            ])
            try Task.checkCancellation()
            guard values.isDirectory == true else { throw VolumeInspectionError.notDirectory }
            guard let canonicalPath = values.canonicalPath, let uuid = values.volumeUUIDString,
                let caseSensitive = values.volumeSupportsCaseSensitiveNames
            else { throw VolumeInspectionError.unavailable }
            return try DirectoryObservation(
                canonicalPath: canonicalPath, volumeUUID: uuid, isCaseSensitive: caseSensitive)
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
