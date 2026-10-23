import Foundation

/// Wire values stay optional; absent counters or future states never imply a healthy backup.
struct KopiaSources: Decodable, Sendable, CustomReflectable {
    let localUsername: String?
    let localHost: String?
    let multiUser: Bool?
    let sources: [KopiaSourceStatus]?

    var customMirror: Mirror { Mirror(self, children: ["sources": "<private>"]) }
}
