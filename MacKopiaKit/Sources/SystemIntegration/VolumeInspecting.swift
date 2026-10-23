/// Resolves the current volume of an existing directory, never a stored mount-point name or parent fallback.
package protocol VolumeInspecting: Sendable {
    func volumeUUID(forDirectory path: String) async throws -> String
}
