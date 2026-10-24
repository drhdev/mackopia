import BackupDomain
import Foundation
import Persistence

extension JobQueue {
    func detachPausePersistence() { pausePersistence = nil }

    /// Restore only into a fresh queue, before any scheduler, event source, or consumer starts.
    func restorePauses(planIDs: Set<UUID>) throws {
        guard let pausePersistence else { return }
        guard canRestorePauses else { throw ConfigStoreError.storageChanged }
        let date = now()
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw DomainValidationError.invalidPlan }
        do {
            let loaded = try pausePersistence.load()
            try StoredBackupPause.validate(loaded)
            let relevant = loaded.filter { pause in
                if let id = pause.planID, !planIDs.contains(id) { return false }
                if case .until(let deadline) = pause.state { return deadline > date }
                return true
            }
            try savePauses(relevant)
            for pause in relevant {
                let state = BackupPauseState(pause.state)
                _ = replacePause(planID: pause.planID, state: state)
                if case .until(let deadline) = state { armPauseTimer(planID: pause.planID, until: deadline) }
            }
        } catch {
            pausePersistenceFailed = true
            signalPausePersistenceFailure()
            throw error
        }
    }

    /// Commit intent before cancellation can suspend. Shutdown uses the in-memory pause primitive
    /// instead, so stopping the runtime never turns into a durable global pause.
    func pausePersistently(planID: UUID?, until: Date?) async throws {
        if let until {
            guard until.timeIntervalSinceReferenceDate.isFinite, until >= .distantPast, until <= .distantFuture else {
                throw DomainValidationError.invalidPlan
            }
        }
        let state: StoredBackupPause.State = until.map { .until($0) } ?? .indefinite
        var snapshot = storedPauses().filter { $0.planID != planID }
        snapshot.append(StoredBackupPause(planID: planID, state: state))
        try savePauses(snapshot)
        if let until { try await pause(planID: planID, until: until) } else { await pause(planID: planID) }
    }

    func storedPauses() -> [StoredBackupPause] {
        pauses.map { scope, pause in StoredBackupPause(planID: scope, state: pause.state.stored) }
    }

    func savePauses(_ snapshot: [StoredBackupPause]) throws {
        guard !pausePersistenceFailed else { throw ConfigStoreError.storageUnavailable }
        do { try pausePersistence?.save(snapshot) } catch {
            pausePersistenceFailed = true
            signalPausePersistenceFailure()
            throw error
        }
    }

    func markTimerUnavailable(planID: UUID?, until: Date) {
        pauses[planID]?.state = .timerUnavailable(until: until)
        // A failed write latches the admission gate closed and wakes the runtime's shutdown path.
        do { try savePauses(storedPauses()) } catch { return }
    }
}

extension BackupPauseState {
    init(_ state: StoredBackupPause.State) {
        switch state {
        case .indefinite: self = .indefinite
        case .until(let date): self = .until(date)
        case .timerUnavailable(let date): self = .timerUnavailable(until: date)
        }
    }

    var stored: StoredBackupPause.State {
        switch self {
        case .indefinite: .indefinite
        case .until(let date): .until(date)
        case .timerUnavailable(let date): .timerUnavailable(until: date)
        }
    }
}
