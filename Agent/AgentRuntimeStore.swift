import AppKit
import BackupDomain
import BackupEngine
import Observation

@Observable @MainActor
final class AgentRuntimeStore {
    @ObservationIgnored lazy var notifications = AgentNotifications()
    var state: LocalServiceState?
    var unavailable = false
    private var observation: Task<Void, Never>?
    private var service: LocalBackupService?

    var statusSymbol: String {
        if state?.activePlanID != nil { return "arrow.triangle.2.circlepath" }
        if state?.issue != nil || state?.plans.contains(where: { $0.health.severity == .critical }) == true {
            return "exclamationmark.triangle"
        }
        if state?.globalPause != nil { return "pause.circle" }
        return "externaldrive.badge.timemachine"
    }
    func name(_ planID: UUID) -> String {
        state?.configuration?.plans.first(where: { $0.id == planID })?.name ?? "MacKopia"
    }

    func observe(_ service: LocalBackupService) {
        self.service = service
        notifications.retry = { [weak self] in self?.run($0) }
        notifications.openDetails = { [weak self] in self?.openApp() }
        observation = Task { [weak self] in
            var revision: UUID?
            do {
                while !Task.isCancelled {
                    let state = try await service.state(after: revision)
                    self?.state = state
                    await self?.notifications.received(state)
                    revision = state.revision
                }
            } catch { if !Task.isCancelled { self?.unavailable = true } }
        }
    }
    func stopObserving() { observation?.cancel(); observation = nil }
    func run(_ id: UUID) { Task { try? await service?.run(id) } }
    func pause(_ option: BackupPauseOption, planID: UUID? = nil) {
        Task { try? await service?.pause(planID: planID, until: option.deadline(after: .now)) }
    }
    func resume(_ planID: UUID? = nil) { Task { try? await service?.resume(planID: planID) } }
    func stop(_ id: UUID) { Task { try? await service?.stop(id) } }
    func openApp() {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
