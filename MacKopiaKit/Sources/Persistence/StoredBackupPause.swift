import Foundation

package struct StoredBackupPause: Codable, Sendable, Equatable {
    package enum State: Codable, Sendable, Equatable {
        case indefinite, until(Date), timerUnavailable(until: Date)
    }

    package let planID: UUID?
    package let state: State

    package init(planID: UUID?, state: State) {
        self.planID = planID
        self.state = state
    }

    package static func validate(_ pauses: [Self]) throws {
        guard pauses.count <= 4097, Set(pauses.map(\.planID)).count == pauses.count else {
            throw ConfigStoreError.invalidConfiguration
        }
        for pause in pauses {
            switch pause.state {
            case .indefinite: break
            case .until(let date), .timerUnavailable(let date):
                guard date.timeIntervalSinceReferenceDate.isFinite, date >= .distantPast, date <= .distantFuture else {
                    throw ConfigStoreError.invalidConfiguration
                }
            }
        }
    }
}

/// Synchronous transactions let the queue persist a transition without actor reentrancy.
package protocol BackupPauseStoring: Sendable {
    func load() throws -> [StoredBackupPause]
    func save(_ pauses: [StoredBackupPause]) throws
}
