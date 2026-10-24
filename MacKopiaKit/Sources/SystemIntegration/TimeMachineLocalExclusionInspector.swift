import BackupDomain
import Darwin
import Foundation

/// Synchronous filesystem calls cannot be forcibly cancelled; callers check their deadline around each await.
package actor TimeMachineLocalExclusionInspector: TimeMachineExclusionInspecting {
    package init() {}

    package func inspect(_ path: String) async throws -> TimeMachineExclusionEntry {
        do {
            try Task.checkCancellation()
            guard DomainValidation.absolutePath(path) else { throw TimeMachineExclusionError.invalidSource }
            var url = URL(fileURLWithPath: path)
            // Refuse symlinks in ancestors as well as in the final component. This is an observation,
            // not a race-free descriptor traversal; callers must still preflight immediately before backup.
            guard
                url.deletingLastPathComponent().resolvingSymlinksInPath().path
                    == url.deletingLastPathComponent().path
            else { throw TimeMachineExclusionError.invalidSource }
            url.removeAllCachedResourceValues()
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .volumeUUIDStringKey, .isExcludedFromBackupKey,
            ])
            guard let directory = values.isDirectory, let symlink = values.isSymbolicLink,
                let volumeUUID = values.volumeUUIDString
            else { throw TimeMachineExclusionError.unavailable }
            if symlink {
                return TimeMachineExclusionEntry(
                    volumeUUID: volumeUUID, isDirectory: directory, isSymbolicLink: true, isExcluded: false)
            }
            guard let excluded = values.isExcludedFromBackup else { throw TimeMachineExclusionError.unavailable }
            // Time Machine writes this namespaced extended attribute for sticky exclusions.
            let size = path.withCString { pointer in
                getxattr(pointer, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, XATTR_NOFOLLOW)
            }
            let attributeError = errno
            guard size >= 0 || attributeError == ENOATTR else { throw TimeMachineExclusionError.unavailable }
            try Task.checkCancellation()
            return TimeMachineExclusionEntry(
                volumeUUID: volumeUUID, isDirectory: directory, isSymbolicLink: false,
                isExcluded: excluded || size >= 0)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let typed = error as? TimeMachineExclusionError { throw typed }
            throw TimeMachineExclusionError.unavailable
        }
    }

    package func children(of path: String, limit: Int) async throws -> [String] {
        try Task.checkCancellation()
        guard limit > 0 else { throw TimeMachineExclusionError.limitExceeded }
        guard DomainValidation.absolutePath(path), URL(fileURLWithPath: path).resolvingSymlinksInPath().path == path
        else {
            throw TimeMachineExclusionError.invalidSource
        }
        var failed = false
        guard
            let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, _ in
                    failed = true
                    return false
                })
        else { throw TimeMachineExclusionError.unavailable }
        var names: [String] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard names.count < limit else { throw TimeMachineExclusionError.limitExceeded }
            names.append(url.lastPathComponent)
        }
        try Task.checkCancellation()
        guard !failed else { throw TimeMachineExclusionError.unavailable }
        return names.sorted()
    }
}
