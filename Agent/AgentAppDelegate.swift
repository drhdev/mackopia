import AgentProtocol
import AppKit
import OSLog

final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    private let server = AgentPingServer()
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacKopia", category: "XPC")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            do {
                guard let agentID = Bundle.main.bundleIdentifier, agentID.hasSuffix(".Agent") else {
                    throw AgentServiceError.invalidIdentity
                }
                let identity = try AgentServiceIdentity(appBundleID: String(agentID.dropLast(".Agent".count)))
                try await server.start(identity: identity)
                logger.info("Authenticated XPC listener started")
            } catch {
                // Static classification only: never forward arbitrary system error descriptions.
                logger.error("Authenticated XPC listener unavailable; check signing and LaunchAgent registration")
            }
        }
    }
}
