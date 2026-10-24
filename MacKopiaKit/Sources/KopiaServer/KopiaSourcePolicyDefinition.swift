import Foundation

/// A complete local definition and the exact selector used to read it, never an effective policy.
/// This is a point-in-time read, not a revision token or authorization to overwrite later changes.
package struct KopiaSourcePolicyDefinition: Sendable, CustomReflectable {
    package let source: KopiaSnapshotSource
    package let document: KopiaPolicyDocument

    package var customMirror: Mirror { Mirror(self, children: ["sourcePolicyDefinition": "<private>"]) }
}
