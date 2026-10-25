import Foundation

/// Bounded projections; object identifiers stay inside the service.
public struct RestoreSnapshot: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let sourcePath: String
    public let user: String
    public let host: String
    public let date: String
    public let bytes: Int64
    public let files: Int64
    public let retention: [String]
    public let pins: [String]
    public let description: String
    public let isIncomplete: Bool
    public init(
        id: String, sourcePath: String, user: String, host: String, date: String,
        bytes: Int64, files: Int64, retention: [String], pins: [String], description: String = "",
        isIncomplete: Bool = false
    ) {
        self.id = id; self.sourcePath = sourcePath; self.user = user; self.host = host
        self.date = date; self.bytes = bytes; self.files = files; self.retention = retention; self.pins = pins;
        self.description = description; self.isIncomplete = isIncomplete
    }
}

public struct RestoreEntry: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public let name: String
    public let isDirectory: Bool
    public let bytes: Int64
    public init(name: String, isDirectory: Bool, bytes: Int64) {
        self.name = name; self.isDirectory = isDirectory; self.bytes = bytes
    }
}

public struct RestoreState: Codable, Sendable {
    public let repositoryID: UUID
    public var snapshots: [RestoreSnapshot] = []
    public var snapshotID: String?
    public var components: [String] = []
    public var entries: [RestoreEntry] = []
    public var matches: [RestoreSearchMatch] = []
    public var searchLimited = false
    public var preview = false
    public var operationID: UUID?
    public var phase: Phase = .idle
    public var bytes: Int64 = 0
    public var files: Int64 = 0
    public var destination: String?
    public enum Phase: String, Codable, Sendable { case idle, running, succeeded, cancelled, failed }
    public init(repositoryID: UUID) { self.repositoryID = repositoryID }
}

public enum RestoreSelection {
    public static func validate(snapshotID: String?, components: [String]) throws {
        if let snapshotID {
            guard !snapshotID.isEmpty, snapshotID.utf8.count <= 128,
                snapshotID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
            else {
                throw LocalServiceIssue.invalidRequest
            }
        } else if !components.isEmpty {
            throw LocalServiceIssue.invalidRequest
        }
        guard components.count <= 64, components.allSatisfy(validComponent) else {
            throw LocalServiceIssue.invalidRequest
        }
    }
    public static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\0")
            && value.utf8.count <= 255
    }
}
