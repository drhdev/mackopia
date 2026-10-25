import BackupDomain
import Foundation

/// Secrets are accepted only in setup commands, never returned in responses or events.
public struct AgentRequest: Codable, Sendable, CustomReflectable {
    public static let currentVersion: UInt32 = 2
    public let version: UInt32
    public let id: UUID
    public let command: Command

    public enum Command: Codable, Sendable {
        case state(after: UUID?)
        case setup(name: String, destination: BackupSource, source: BackupSource, password: String, create: Bool)
        case createPlan(name: String, repositoryID: UUID, source: BackupSource)
        case savePlan(BackupPlan)
        case recoverConfiguration
        case run(UUID)
        case stop(UUID)
    }

    public init(_ command: Command, version: UInt32 = currentVersion, id: UUID = UUID()) {
        self.command = command
        self.version = version
        self.id = id
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw AgentServiceError.incompatibleProtocol }
        guard try JSONEncoder().encode(self).count <= 1_048_576 else { throw LocalServiceIssue.invalidRequest }
        if case .createPlan(let name, _, let source) = command {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
                !name.utf8.contains(0), source.bookmark == nil
            else { throw LocalServiceIssue.invalidRequest }
        }
        if case .setup(let name, let destination, let source, let password, let create) = command {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 1024,
                [name, password].allSatisfy({ !$0.utf8.contains(0) }),
                destination.bookmark == nil, source.bookmark == nil,
                !password.isEmpty, password.utf8.count <= 65_536, !create || password.count >= 12
            else { throw LocalServiceIssue.invalidRequest }
        }
    }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

public struct AgentResponse: Codable, Sendable {
    public let version: UInt32
    public let id: UUID
    public let state: LocalServiceState?
    public let issue: LocalServiceIssue?
    public init(id: UUID, state: LocalServiceState? = nil, issue: LocalServiceIssue? = nil) {
        self.version = AgentRequest.currentVersion
        self.id = id
        self.state = state
        self.issue = issue
    }
}
