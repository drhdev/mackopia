import BackupDomain

/// Only the engine may resolve a reference into a memory-only payload, never the UI or an XPC event.
package protocol SecretStore: Sendable {
    func read(_ reference: SecretRef) async throws -> SecretValue?
    func write(_ value: SecretValue, for reference: SecretRef) async throws
    func delete(_ reference: SecretRef) async throws
}
