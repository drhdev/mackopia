import Foundation

extension AutomaticBackupRuntime {
    func startRecoveryDelay() {
        let deadline = clock.now.advanced(
            by: .seconds(max(120, loginDate.addingTimeInterval(60).timeIntervalSince(now()))))
        let clock = clock
        recoveryTask = Task { [weak self] in
            await AutomaticWorker.$kind.withValue(.recovery) {
                do {
                    try await clock.sleep(until: deadline, tolerance: nil)
                    try Task.checkCancellation()
                    await self?.releaseRecovery()
                } catch {
                    if !Task.isCancelled { await self?.controlStateFailed() }
                }
            }
        }
    }

    private func releaseRecovery() async {
        guard state == .running else { return }
        await queue.releaseRecovery()
    }
}
