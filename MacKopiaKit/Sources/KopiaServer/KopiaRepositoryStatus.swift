import Foundation

/// Unknown fields are ignored; absent fields remain unknown rather than implying a healthy backup.
struct KopiaRepositoryStatus: Decodable, Sendable {
    let connected: Bool?
    let formatVersion: Int?
    let storage: String?
}
