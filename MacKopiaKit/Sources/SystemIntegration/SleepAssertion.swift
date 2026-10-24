import Foundation
import IOKit.pwr_mgt
import Synchronization

package protocol SleepAssertionHolding: Sendable {
    func release()
}

package protocol SleepPreventing: Sendable {
    func acquire() throws -> any SleepAssertionHolding
}

/// Prevents idle system sleep only; explicit sleep and display sleep remain controlled by macOS.
package struct LocalSleepPreventer: SleepPreventing {
    package init() {}

    package func acquire() throws -> any SleepAssertionHolding {
        try Task.checkCancellation()
        var identifier: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacKopia-Backup läuft" as CFString, &identifier)
        guard result == kIOReturnSuccess else { throw SleepAssertionError.unavailable }
        return SleepAssertion(identifier: identifier) { _ = IOPMAssertionRelease($0) }
    }
}

/// Explicit release and deinit share one atomic take, including concurrent cleanup calls.
package final class SleepAssertion: SleepAssertionHolding {
    private let identifier: Mutex<IOPMAssertionID?>
    private let relinquish: @Sendable (IOPMAssertionID) -> Void

    init(identifier: IOPMAssertionID, relinquish: @escaping @Sendable (IOPMAssertionID) -> Void) {
        self.identifier = Mutex(identifier)
        self.relinquish = relinquish
    }

    package func release() {
        let value = identifier.withLock { value in
            let current = value
            value = nil
            return current
        }
        if let value { relinquish(value) }
    }

    deinit { release() }
}

package enum SleepAssertionError: Error, Equatable, LocalizedError, CustomDebugStringConvertible {
    case unavailable

    package var errorDescription: String? {
        String(localized: "Die Sicherung konnte nicht abgeschlossen werden.")
    }

    package var debugDescription: String { "Backup idle sleep prevention is unavailable" }
}
