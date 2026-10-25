import Foundation
import KopiaCLI
import SystemIntegration

/// Fresh evidence in both the service and the exact bundled Kopia child; never a saved FDA flag.
struct AgentFullDiskAccessProbe: FullDiskAccessProbing {
    let executable: URL
    let home: URL
    let temporary: URL

    func probe() async throws -> FullDiskAccessObservation {
        let agent = try await LocalFullDiskAccessProbe(home: home).probe()
        guard agent == .readable else { return agent }
        do {
            return try await KopiaProtectedFileProbe(executable: executable, home: home, temporary: temporary)
                .canReadProtectedFile() ? .readable : .unknown
        } catch is CancellationError { throw CancellationError() } catch { return .unknown }
    }
}
