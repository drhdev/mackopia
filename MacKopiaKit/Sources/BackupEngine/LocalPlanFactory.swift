import BackupDomain
import Foundation

/// New plans use the same supported, manual-only defaults in setup and existing destinations.
enum LocalPlanFactory {
    static func make(name: String, source: BackupSource, repositoryID: UUID) throws -> BackupPlan {
        try BackupPlan(
            name: name, isEnabled: true, repositoryID: repositoryID, sources: [source], triggers: [.manual],
            conditions: RunConditions(
                requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
            retention: RetentionPolicy(preset: .balanced),
            excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: true, ignoreCacheDirs: true),
            options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
    }
}
