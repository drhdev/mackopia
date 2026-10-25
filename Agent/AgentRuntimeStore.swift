import AppKit
import BackupDomain
import BackupEngine
import Observation

@Observable @MainActor
final class AgentRuntimeStore {
    var state: LocalServiceState?
    var unavailable = false
    private var observation: Task<Void, Never>?
    private var service: LocalBackupService?

    func observe(_ service: LocalBackupService) {
        self.service = service
        observation = Task { [weak self] in
            var revision: UUID?
            do {
                while !Task.isCancelled {
                    let state = try await service.state(after: revision)
                    self?.state = state
                    revision = state.revision
                }
            } catch { if !Task.isCancelled { self?.unavailable = true } }
        }
    }
    func stopObserving() { observation?.cancel(); observation = nil }
    func run(_ id: UUID) { Task { try? await service?.run(id) } }
    func stop(_ id: UUID) { Task { try? await service?.stop(id) } }
    func openApp() {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
