import Foundation

package enum AutomaticBackupState: Sendable, Equatable {
    case idle, starting, running, stopping, stopped, monitorUnavailable
}

/// Fixed codes only; arbitrary adapter diagnostics never reach the runtime's event boundary.
package enum AutomaticBackupIssue: Sendable, Equatable {
    case monitorUnavailable, backupFailed(planID: UUID), admissionRejected(planID: UUID)
}
