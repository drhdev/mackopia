import Foundation

/// Captures the monotonic deadline before task scheduling or operation cleanup can suspend.
struct BackupPauseTimer: Sendable {
    let start:
        @Sendable (
            UUID, Duration, @escaping @Sendable (Bool) async -> Void
        ) -> Task<Void, Never>

    init<C: Clock>(clock: C) where C.Duration == Duration {
        start = { id, delay, fire in
            let deadline = clock.now.advanced(by: delay)
            return Task {
                await PauseTimerWorker.$id.withValue(id) {
                    do {
                        try await clock.sleep(until: deadline, tolerance: nil)
                        try Task.checkCancellation()
                        await fire(true)
                    } catch {
                        if !Task.isCancelled { await fire(false) }
                    }
                }
            }
        }
    }
}

enum PauseTimerWorker {
    @TaskLocal static var id: UUID?
}
