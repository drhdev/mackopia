import BackupDomain
import Foundation

/// An immutable request snapshot. Its ID identifies this admission, not the backup plan.
package struct BackupJob: Sendable, Equatable, Identifiable {
    package let id: UUID
    package let plan: BackupPlan
    package let trigger: Trigger
    package let requestedAt: Date
}
