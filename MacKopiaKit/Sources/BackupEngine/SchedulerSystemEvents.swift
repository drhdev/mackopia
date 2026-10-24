import Foundation
import SystemIntegration

extension Scheduler {
    /// The caller owns this structured subscription and cancels it on service shutdown.
    /// Other events are forwarded as hints; they never bypass fresh preflight or authorize uploads.
    package func observeSystemEvents(
        using monitor: any SystemEventMonitoring,
        calendar: @escaping @Sendable () -> Calendar = { .current },
        changed: @escaping @Sendable (SystemEvent) async -> Void = { _ in }
    ) async throws {
        try await monitor.observe { event in
            guard !Task.isCancelled else { return }
            switch event {
            case .woke, .clockChanged: await self.reconcile()
            case .timeZoneChanged: await self.reconcile(calendar: calendar())
            default: break
            }
            await changed(event)
        }
    }
}
