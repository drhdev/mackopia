import BackupDomain
import Foundation

/// Reads fresh resource values on the actor executor. Never creates directories or mounts a volume.
package actor LocalVolumeInspector: VolumeInspecting {
    private let resources: any VolumeResourceReading

    package init() { resources = FoundationVolumeResources() }
    init(resources: any VolumeResourceReading) { self.resources = resources }

    package func volumeUUID(forDirectory path: String) async throws -> String {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { throw VolumeInspectionError.invalidPath }
        do {
            let uuid = try resources.volumeUUID(forDirectory: URL(fileURLWithPath: path))
            try Task.checkCancellation()
            guard let uuid, let identifier = DomainValidation.volumeUUID(uuid) else {
                throw VolumeInspectionError.unavailable
            }
            return identifier.uuidString
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

protocol VolumeResourceReading: Sendable {
    func volumeUUID(forDirectory url: URL) throws -> String?
}

struct FoundationVolumeResources: VolumeResourceReading {
    func volumeUUID(forDirectory url: URL) throws -> String? {
        // Follow symlinks before inspecting: the target volume is the one Kopia would actually read.
        let resolved = url.resolvingSymlinksInPath()
        var fresh = URL(fileURLWithPath: resolved.path)
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey])
        guard values.isDirectory == true else { throw VolumeInspectionError.notDirectory }
        return values.volumeUUIDString
    }
}
