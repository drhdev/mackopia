import Foundation

public struct BackupPlan: Codable, Sendable, Hashable, Identifiable, CustomReflectable {
    public let id: UUID
    public let name: String
    public let isEnabled: Bool
    public let repositoryID: UUID
    public let sources: [BackupSource]
    public let triggers: [Trigger]
    public let conditions: RunConditions
    public let retention: RetentionPolicy
    public let excludes: ExcludeRules
    public let options: PlanOptions
    public let health: HealthThresholds

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool,
        repositoryID: UUID,
        sources: [BackupSource],
        triggers: [Trigger],
        conditions: RunConditions,
        retention: RetentionPolicy,
        excludes: ExcludeRules,
        options: PlanOptions,
        health: HealthThresholds
    ) throws {
        guard DomainValidation.text(name, limit: 1024), !sources.isEmpty, sources.count <= 1024,
            Set(sources.map(\.id)).count == sources.count,
            Set(sources.map(\.path)).count == sources.count,
            !triggers.isEmpty, triggers.count <= 64, Set(triggers).count == triggers.count
        else { throw DomainValidationError.invalidPlan }
        for trigger in triggers { try trigger.validate() }
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.repositoryID = repositoryID
        self.sources = sources
        self.triggers = triggers
        self.conditions = conditions
        self.retention = retention
        self.excludes = excludes
        self.options = options
        self.health = health
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(UUID.self, forKey: .id),
            name: c.decode(String.self, forKey: .name),
            isEnabled: c.decode(Bool.self, forKey: .isEnabled),
            repositoryID: c.decode(UUID.self, forKey: .repositoryID),
            sources: c.decode([BackupSource].self, forKey: .sources),
            triggers: c.decode([Trigger].self, forKey: .triggers),
            conditions: c.decode(RunConditions.self, forKey: .conditions),
            retention: c.decode(RetentionPolicy.self, forKey: .retention),
            excludes: c.decode(ExcludeRules.self, forKey: .excludes),
            options: c.decode(PlanOptions.self, forKey: .options),
            health: c.decode(HealthThresholds.self, forKey: .health))
    }

    public var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }
}
