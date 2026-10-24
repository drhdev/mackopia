import Foundation

/// Trusted engine boundary; callers hold their repository operation reservation throughout synchronization.
package protocol KopiaPolicyServing: Sendable {
    func policyDefinition(source: KopiaSnapshotSource) async throws -> KopiaSourcePolicyDefinition?
    func previewPolicy(source: KopiaSnapshotSource, updates: KopiaPolicyDocument?) async throws -> KopiaPolicyDocument
    func replacePolicy(source: KopiaSnapshotSource, document: KopiaPolicyDocument) async throws
}
