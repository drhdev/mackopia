import Foundation

package struct LocalVolumeProtectionMonitor: VolumeProtectionStarting {
    private let resolver = LocalVolumeProtectionResolver()

    package init() {}

    package func start(directories: [ProtectedDirectory]) async throws -> any VolumeProtectionSession {
        try Task.checkCancellation()
        let volumes = try await resolver.resolve(directories)
        let session = try await DiskVolumeProtectionSession(volumes: volumes)
        do {
            try Task.checkCancellation()
            return session
        } catch {
            await session.close()
            throw error
        }
    }
}
