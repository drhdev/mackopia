import Foundation

struct ResolvedProtectedVolume: Sendable {
    let device: String
    let mountPath: String
    let uuid: String
}

/// Filesystem metadata can block; resolve it off MainActor before registering native callbacks.
actor LocalVolumeProtectionResolver {
    func resolve(_ directories: [ProtectedDirectory]) throws -> [ResolvedProtectedVolume] {
        guard !directories.isEmpty, directories.count <= 1025 else { throw VolumeProtectionError.unavailable }
        var volumes: [ResolvedProtectedVolume] = []
        do {
            for directory in directories {
                try Task.checkCancellation()
                var url = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath()
                url.removeAllCachedResourceValues()
                // APFS firmlinks: Foundation may report "/" as volumeURL for Data-volume directories.
                // statfs resolves the actual backing device; DA must independently confirm its UUID.
                let mount = try LocalVolumeMount(directory: url)
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .volumeUUIDStringKey, .volumeIsLocalKey])
                guard values.isDirectory == true, values.volumeIsLocal == true,
                    values.volumeUUIDString?.uppercased() == directory.volumeUUID
                else { throw VolumeProtectionError.unavailable }
                if let previous = volumes.first(where: { $0.device == mount.device }) {
                    guard previous.uuid == directory.volumeUUID, previous.mountPath == mount.path else {
                        throw VolumeProtectionError.unavailable
                    }
                } else {
                    volumes.append(
                        ResolvedProtectedVolume(device: mount.device, mountPath: mount.path, uuid: directory.volumeUUID)
                    )
                }
            }
            try Task.checkCancellation()
            return volumes
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw VolumeProtectionError.unavailable
        }
    }
}
