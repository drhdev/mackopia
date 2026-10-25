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
    enum Schedule: String, CaseIterable { case manual, interval, daily, custom }
    var schedule: Schedule = .manual
    var minutes = 60
    var time = Date.now
    var onMount = false
    var hasCustomSchedule: Bool { Self.usesCustomSchedule(original) }
    var requiresACPower: Bool
    var catchUp: Bool
    var eject: Bool
    var canEject: Bool {
        guard let repo = connection.state?.configuration?.repositories.first(where: { $0.id == original.repositoryID }),
            case .filesystem(_, let volume) = repo.kind
        else { return false }
        return volume?.isRemovable == true && volume?.isNetwork == false
    }
    var localError = false
    var hasCustomRetention: Bool { original.retention.preset == .custom }

    init(plan: BackupPlan, connection: AgentConnection) {
        original = plan
        self.connection = connection
        eject = plan.options.ejectVolumeAfterBackup
        requiresACPower = plan.conditions.requiresACPower
        catchUp = plan.conditions.catchUpMissedRuns
        for trigger in plan.triggers {
            switch trigger {
            case .interval(let value): schedule = .interval; minutes = value
            case .daily(let hour, let minute, _):
                schedule = .daily
                time = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now
            case .onVolumeMount: onMount = true
            default: break
            }
        }
        if Self.usesCustomSchedule(plan) { schedule = .custom }
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
                sources: sources, triggers: triggers(),
                conditions: RunConditions(
                    requiresACPower: requiresACPower, minBatteryPercent: original.conditions.minBatteryPercent,
                    skipOnExpensiveNetwork: original.conditions.skipOnExpensiveNetwork,
                    skipOnConstrainedNetwork: original.conditions.skipOnConstrainedNetwork,
                    allowedWiFiSSIDs: original.conditions.allowedWiFiSSIDs, catchUpMissedRuns: catchUp),
                retention: retention == .custom ? original.retention : RetentionPolicy(preset: retention),
                excludes: original.excludes,
                options: PlanOptions(
                    compression: original.options.compression, parallelism: original.options.parallelism,
                    lowPriority: original.options.lowPriority, uploadLimitMbps: original.options.uploadLimitMbps,
                    ejectVolumeAfterBackup: eject, plausibilityDropPercent: original.options.plausibilityDropPercent),
                health: original.health)
            connection.send(.savePlan(updated), completed: completed)
        } catch { localError = true }
    }
    private func triggers() -> [Trigger] {
        var result: [Trigger] = [.manual]
        switch schedule {
        case .manual: break
        case .custom: result += original.triggers.filter(Self.isTimeTrigger)
        case .interval: result.append(.interval(minutes: minutes))
        case .daily:
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            result.append(.daily(hour: parts.hour ?? 8, minute: parts.minute ?? 0, weekdays: Set(Weekday.allCases)))
        }
        if onMount { result.append(.onVolumeMount) }
        if original.triggers.contains(.onNetworkReachable) { result.append(.onNetworkReachable) }
        return result
    }

    private static func usesCustomSchedule(_ plan: BackupPlan) -> Bool {
        plan.triggers.filter(isTimeTrigger).count > 1
            || plan.triggers.contains {
                if case .daily(_, _, let weekdays) = $0 { return weekdays != Set(Weekday.allCases) }
                return false
            }
    }

    private static func isTimeTrigger(_ trigger: Trigger) -> Bool {
        switch trigger {
        case .interval, .daily: true;
        default: false
        }
    }

}
