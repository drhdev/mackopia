import Foundation
import KopiaCLI
import Secrets

/// A diagnostic observation, never a reusable authorization to start a snapshot.
package struct BackupPreflightReport: Sendable, Equatable, CustomReflectable {
    package enum Outcome: Sendable, Equatable { case checksPassed, blocked, skipped }
    package let outcome: Outcome
    package let checks: [BackupPreflightCheck]
    package let sources: [SourcePathStatus]

    package var customMirror: Mirror { Mirror(self, children: ["report": "<private>"]) }
}

package struct BackupPreflightCheck: Sendable, Equatable {
    package enum Step: Sendable, Equatable {
        case configuration, binary, backupPassword, destinationIdentity, destinationAccess, destinationCapacity
        case sourceIdentity, sourceAccess, runConditions, repositoryExclusion
    }
    package enum Status: Sendable, Equatable { case passed, warning, blocked, skipped }
    package let step: Step
    package let status: Status
    package let issue: BackupPreflightIssue?

    package var action: BackupPreflightAction? { issue?.action }
}

package enum BackupPreflightIssue: Sendable, Equatable {
    case binary(KopiaBinaryVerificationError), keychain(SecretStoreError), configuration(BackupPreflightError)
    case operation(RepositoryOperationError), conditions(RunConditionSkipReason)
    case destinationAccessDenied, destinationAccessUnknown, sourceAccessDenied, sourceAccessUnknown
    case lowDestinationSpace, insufficientDestinationSpace, sourcesSkipped, noAvailableSources, checkFailed

    package var action: BackupPreflightAction {
        switch self {
        case .binary: .repairApplication
        case .keychain: .checkKeychain
        case .configuration(.backupPasswordRequired): .enterBackupPassword
        case .configuration(.destinationUnavailable), .configuration(.destinationVolumeMismatch),
            .configuration(.unboundDestination):
            .connectDestination
        case .configuration(.destinationPermissionDenied), .destinationAccessDenied, .destinationAccessUnknown:
            .checkDestinationAccess
        case .configuration: .reviewConfiguration
        case .operation: .waitForOperation
        case .conditions: .reviewRunConditions
        case .sourceAccessDenied, .sourceAccessUnknown: .checkSourceAccess
        case .lowDestinationSpace, .insufficientDestinationSpace: .freeDestinationSpace
        case .sourcesSkipped, .noAvailableSources: .checkSources
        case .checkFailed: .retry
        }
    }
}

package enum BackupPreflightAction: Sendable, Equatable {
    case repairApplication, checkKeychain, enterBackupPassword, connectDestination, checkDestinationAccess
    case reviewConfiguration, waitForOperation, reviewRunConditions, checkSourceAccess, freeDestinationSpace
    case checkSources, retry
}
