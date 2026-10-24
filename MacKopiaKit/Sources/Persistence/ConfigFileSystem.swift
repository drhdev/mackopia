import Foundation

// All calls inside a transaction are synchronous: the actor cannot suspend between comparison and replacement.
protocol ConfigFileAccess {
    func read(_ file: ConfigFile) throws -> Data?
    func replace(_ file: ConfigFile, with data: Data) throws
}

protocol ConfigFileSystem: Sendable {
    func withLock<T>(_ operation: (any ConfigFileAccess) throws -> T) throws -> T
}

enum ConfigFile: String { case primary = "config.json", backup = "config.json.bak", pauses = "pauses.json" }
