import Foundation

public struct BackupConfiguration: Codable, Sendable, Hashable, CustomReflectable {
    public let repositories: [Repository]
    public let plans: [BackupPlan]

    public init(repositories: [Repository] = [], plans: [BackupPlan] = []) throws {
        guard repositories.count <= 1024, plans.count <= 4096 else { throw DomainValidationError.invalidPlan }
        try PlanSetValidator.validate(plans: plans, repositories: repositories)
        self.repositories = repositories
        self.plans = plans
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            repositories: c.decode([Repository].self, forKey: .repositories),
            plans: c.decode([BackupPlan].self, forKey: .plans))
    }

    public var customMirror: Mirror { Mirror(self, children: ["configuration": "<private>"]) }
}
