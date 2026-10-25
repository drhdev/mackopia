import Foundation

public struct RestoreSearchMatch: Codable, Sendable, Identifiable, Hashable {
    public var id: [String] { components }
    public let components: [String]
    public let isDirectory: Bool
    public init(components: [String], isDirectory: Bool) {
        self.components = components; self.isDirectory = isDirectory
    }
}
