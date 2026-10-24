import Foundation

/// Wire values stay optional; absent counters or future states never imply a healthy backup.
package struct KopiaSources: Decodable, Sendable, CustomReflectable {
    package let localUsername: String?
    package let localHost: String?
    package let multiUser: Bool?
    package let sources: [KopiaSourceStatus]?

    package var customMirror: Mirror { Mirror(self, children: ["sources": "<private>"]) }
}
