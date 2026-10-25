import AgentProtocol
import AppKit
import BackupEngine
import OSLog
import Observation

@Observable
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AgentRuntimeStore()
    private let server = AgentServiceServer()
    private var service: LocalBackupService?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacKopia", category: "XPC")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                guard let agentID = Bundle.main.bundleIdentifier, agentID.hasSuffix(".Agent") else {
                    throw AgentServiceError.invalidIdentity
                }
                let identity = try AgentServiceIdentity(appBundleID: String(agentID.dropLast(".Agent".count)))
                let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                struct Pin: Decodable { let version: String }
                let pin = try JSONDecoder().decode(
                    Pin.self, from: Data(contentsOf: app.appending(path: "Contents/Resources/Kopia/kopia-version.json"))
                )
                let service = try LocalBackupService(
                    executable: app.appending(path: "Contents/Helpers/kopia"),
                    home: FileManager.default.homeDirectoryForCurrentUser,
                    temporary: FileManager.default.temporaryDirectory,
                    expectedVersion: pin.version)
                self.service = service
                try await service.start()
                try await server.start(identity: identity) { command in
                    switch command {
                    case .state(let revision): return try await service.state(after: revision)
                    case .setup(let name, let destination, let source, let password, let create):
                        try await service.setup(
                            name: name, destination: destination, source: source, password: password, create: create)
                    case .createPlan(let name, let repositoryID, let source):
                        try await service.createPlan(name: name, repositoryID: repositoryID, source: source)
                    case .recoverConfiguration: try await service.recoverConfiguration()
                    case .savePlan(let plan): try await service.savePlan(plan)
                    case .run(let id): try await service.run(id)
                    case .setNotificationsEnabled(let enabled):
                        try await service.setNotificationsEnabled(enabled)
                        if enabled { await self.runtime.notifications.requestPermission() }
                    case .restartAutomation: try await service.restartAutomation()
                    case .verify(let id): try await service.verify(id)
                    case .stop(let id): try await service.stop(id)
                    case .pause(let id, let until): try await service.pause(planID: id, until: until)
                    case .resume(let id): try await service.resume(planID: id)
                    }
                    return try await service.state()
                }
                runtime.observe(service)
                logger.info("Authenticated backup service started")
            } catch {
                runtime.unavailable = true
                logger.error("Backup service unavailable; check installation and service permissions")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            runtime.stopObserving()
            await server.stop()
            await service?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
