import BackupDomain
import Foundation
import Observation

@Observable @MainActor
final class PlanEditorStore {
    private let original: BackupPlan
    let connection: AgentConnection
    var name: String
    var enabled: Bool
    var retention: RetentionPreset
    var sources: [BackupSource]
    var localError = false
    var hasCustomRetention: Bool { original.retention.preset == .custom }

    init(plan: BackupPlan, connection: AgentConnection) {
        original = plan
        self.connection = connection
        name = plan.name; enabled = plan.isEnabled; retention = plan.retention.preset; sources = plan.sources
    }

    func addSource() {
        connection.chooseDirectory { source in
            if !self.sources.contains(where: { $0.path == source.path }) { self.sources.append(source) }
        }
    }
    func removeSource(_ id: UUID) { if sources.count > 1 { sources.removeAll { $0.id == id } } }
    func save(completed: @escaping () -> Void) {
        do {
            let updated = try BackupPlan(
                id: original.id, name: name, isEnabled: enabled, repositoryID: original.repositoryID,
                sources: sources, triggers: original.triggers, conditions: original.conditions,
                retention: retention == .custom ? original.retention : RetentionPolicy(preset: retention),
                excludes: original.excludes, options: original.options, health: original.health)
            connection.send(.savePlan(updated), completed: completed)
        } catch { localError = true }
    }
}
