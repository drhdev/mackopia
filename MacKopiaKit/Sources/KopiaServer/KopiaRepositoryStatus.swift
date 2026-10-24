import Foundation

/// Unknown fields are ignored; absent fields remain unknown rather than implying a healthy backup.
package struct KopiaRepositoryStatus: Decodable, Sendable {
    package let connected: Bool?
    package let formatVersion: Int?
    package let storage: String?
}
