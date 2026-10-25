import BackupDomain
import Foundation

enum PreviewData {
    @MainActor static func connection(
        empty: Bool = false, issue: LocalServiceIssue? = nil, paused: Bool = false, critical: Bool = false
    ) -> AgentConnection {
        let connection = AgentConnection(preview: true)
        connection.connected = true
        do {
            let volume = try VolumeIdentity(
                uuid: "11111111-1111-1111-1111-111111111111", name: "Preview", isRemovable: false, isNetwork: false)
            let repository = try Repository(
                name: "Backup", kind: .filesystem(path: "/Preview/Backup", volume: volume),
                identity: SnapshotIdentity(overrideUser: "preview", overrideHost: "preview"), secretRef: SecretRef())
            let plan = try BackupPlan(
                name: "Dokumente", isEnabled: true, repositoryID: repository.id,
                sources: [BackupSource(path: "/Preview/Documents", volume: volume)], triggers: [.manual],
                conditions: RunConditions(
                    requiresACPower: false, skipOnExpensiveNetwork: false, skipOnConstrainedNetwork: false),
                retention: RetentionPolicy(preset: .balanced),
                excludes: ExcludeRules(useMacOSDefaults: true, honorTimeMachineExclusions: true, ignoreCacheDirs: true),
                options: PlanOptions(lowPriority: true, ejectVolumeAfterBackup: false), health: HealthThresholds())
            connection.state = LocalServiceState(
                configuration: try BackupConfiguration(
                    repositories: empty ? [] : [repository], plans: empty ? [] : [plan]), issue: issue,
                plans: empty
                    ? []
                    : [
                        PlanRuntimeState(
                            planID: plan.id,
                            nextRun: .now.addingTimeInterval(3600), pause: paused ? .indefinite : nil,
                            health: HealthAssessment(
                                planID: plan.id, lastSuccessfulBackup: .now.addingTimeInterval(-1800),
                                reasons: critical ? [.verificationFailed] : [.verificationUnavailable]),
                            verification: nil, testRestore: nil, maintenance: nil)
                    ])
            connection.message = issue.map(AgentConnection.description)
        } catch { connection.message = AgentConnection.description(.invalidRequest) }
        return connection
    }
}
