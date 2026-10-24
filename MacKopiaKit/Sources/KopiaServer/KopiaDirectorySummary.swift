import Foundation

package struct KopiaDirectorySummary: Decodable, Sendable {
    package let size: Int64?
    package let files: Int64?
    package let symlinks: Int64?
    package let dirs: Int64?
    package let numFailed: Int64?
    package let maxTime: String?
}
