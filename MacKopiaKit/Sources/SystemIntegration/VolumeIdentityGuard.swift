import BackupDomain

/// A point-in-time preflight, not an authorization token: recheck immediately before starting an operation.
package struct VolumeIdentityGuard: Sendable {
    private let inspector: any VolumeInspecting

    package init(inspector: any VolumeInspecting = LocalVolumeInspector()) { self.inspector = inspector }

    package func validateSource(_ source: BackupSource) async throws {
        try await validateDirectory(path: source.path, expected: source.volume)
    }

    /// Also applies to an existing filesystem destination; creation of a new destination is a separate flow.
    package func validateDirectory(path: String, expected: VolumeIdentity) async throws {
        try Task.checkCancellation()
        guard DomainValidation.absolutePath(path) else { throw VolumeInspectionError.invalidPath }
        let observed = try await inspector.volumeUUID(forDirectory: path)
        try Task.checkCancellation()
        try expected.requireMatch(uuid: observed)
    }
}
