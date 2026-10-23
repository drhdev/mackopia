import Foundation

/// Validate the complete prospective configuration before persisting an insertion or replacement.
public enum PlanSetValidator {
    public static func validate(plans: [BackupPlan], repositories: [Repository]) throws {
        let repositoryIDs = Set(repositories.map(\.id))
        guard repositoryIDs.count == repositories.count,
            Set(plans.map(\.id)).count == plans.count
        else { throw DomainValidationError.invalidPlan }
        var sourcesByRepository: [UUID: Set<String>] = [:]
        for plan in plans {
            guard repositoryIDs.contains(plan.repositoryID) else { throw DomainValidationError.invalidPlan }
            for source in plan.sources {
                // Kopia policies address the literal user@host:path, independent of our source/volume UUIDs.
                // Include disabled plans: enabling one later must not silently replace another plan's policy.
                guard sourcesByRepository[plan.repositoryID, default: []].insert(source.path).inserted else {
                    throw DomainValidationError.sourceConflict
                }
            }
        }
    }
}
