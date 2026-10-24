import BackupDomain
import Foundation

/// Successful starts anchor recurring schedules; interrupted and failed attempts never imply success.
package protocol JobHistoryScheduleReading: Sendable {
    func scheduleAnchors(plans: [BackupPlan], before: Date) async throws -> [UUID: Date]
}
