import Foundation

struct KopiaResolvedPolicy: Decodable, Sendable, CustomReflectable {
    let defined: KopiaPolicy?
    let effective: KopiaPolicy?
    let definition: Definition?

    /// Origin of individual fields. Global/user/host policies may have empty source components.
    struct Definition: Decodable, Sendable, CustomReflectable {
        let retention: [String: KopiaSourceStatus.Source]?
        let files: [String: KopiaSourceStatus.Source]?
        let compression: [String: KopiaSourceStatus.Source]?

        var customMirror: Mirror { Mirror(self, children: ["origins": "<private>"]) }
    }

    var customMirror: Mirror { Mirror(self, children: ["resolvedPolicy": "<private>"]) }
}
