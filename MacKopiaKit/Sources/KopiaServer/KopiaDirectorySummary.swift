import Foundation

struct KopiaDirectorySummary: Decodable, Sendable {
    let size: Int64?
    let files: Int64?
    let symlinks: Int64?
    let dirs: Int64?
    let numFailed: Int64?
    let maxTime: String?
}
