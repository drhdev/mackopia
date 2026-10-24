import Foundation

package enum BackupPauseState: Sendable, Equatable {
    case indefinite, until(Date), timerUnavailable(until: Date)
}
