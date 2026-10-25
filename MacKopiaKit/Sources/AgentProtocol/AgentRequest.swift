import BackupDomain
import Foundation

/// Secrets are accepted only in setup commands, never returned in responses or events.
public struct AgentRequest: Codable, Sendable, CustomReflectable {
    public static let currentVersion: UInt32 = 4
    public let version: UInt32
    public let id: UUID
    public let command: Command

    public enum Command: Codable, Sendable {
        case state(after: UUID?)
        case browse(repositoryID: UUID, snapshotID: String?, components: [String])
        case restore(repositoryID: UUID, snapshotID: String, components: [String], destination: BackupSource)
        case cancelRestore(UUID)
        case searchRestore(repositoryID: UUID, snapshotID: String, query: String)
        case previewRestore(repositoryID: UUID, snapshotID: String, components: [String])
        case clearRestorePreview
        case editSnapshot(repositoryID: UUID, snapshotID: String, description: String, pinned: Bool)
        case setup(name: String, destination: BackupSource, source: BackupSource, password: String, create: Bool)
        case createPlan(name: String, repositoryID: UUID, source: BackupSource)
        case savePlan(BackupPlan)
        case recoverConfiguration
        case run(UUID)
        case stop(UUID)
        case verify(UUID)
        case restartAutomation
        case setNotificationsEnabled(Bool)
        case pause(planID: UUID?, until: Date?)
        case resume(planID: UUID?)
    }

    public init(_ command: Command, version: UInt32 = currentVersion, id: UUID = UUID()) {
        self.command = command
        self.version = version
        self.id = id
    }

    public func validate() throws {
        guard version == Self.currentVersion else { throw AgentServiceError.incompatibleProtocol }
        guard let encoded = try? JSONEncoder().encode(self), encoded.count <= 1_048_576 else {
            throw LocalServiceIssue.invalidRequest
        }
        switch command {
        case .editSnapshot(_, let id, let description, _):
            try RestoreSelection.validate(snapshotID: id, components: [])
            guard description.utf8.count <= 4096, !description.utf8.contains(0) else {
                throw LocalServiceIssue.invalidRequest
            }
        case .searchRestore(_, let id, let query):
            try RestoreSelection.validate(snapshotID: id, components: [])
            guard !query.isEmpty, query.utf8.count <= 256, !query.utf8.contains(0) else {
                throw LocalServiceIssue.invalidRequest
            }
        case .previewRestore(_, let id, let components):
            try RestoreSelection.validate(snapshotID: id, components: components)
            guard !components.isEmpty else { throw LocalServiceIssue.invalidRequest }
        case .browse(_, let id, let components): try RestoreSelection.validate(snapshotID: id, components: components)
        case .restore(_, let id, let components, let destination):
            try RestoreSelection.validate(snapshotID: id, components: components)
            guard destination.bookmark == nil else { throw LocalServiceIssue.invalidRequest }
        default: break
        }
        if case .pause(_, let until) = command, let until {
            guard until.timeIntervalSinceReferenceDate.isFinite, until >= .distantPast, until <= .distantFuture else {
                throw LocalServiceIssue.invalidRequest
            }
        }
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
