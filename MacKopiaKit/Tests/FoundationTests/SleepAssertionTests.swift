import Synchronization
import Testing

@testable import SystemIntegration

struct SleepAssertionTests {
    @Test func concurrentReleaseAndDeinitRelinquishExactlyOnce() async {
        let released = Mutex<[UInt32]>([])
        do {
            let assertion = SleepAssertion(identifier: 42) { id in released.withLock { $0.append(id) } }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<20 { group.addTask { assertion.release() } }
            }
        }
        #expect(released.withLock { $0 } == [42])
    }

    @Test func forgottenExplicitReleaseIsRecoveredByDeinit() {
        let released = Mutex<[UInt32]>([])
        do {
            let assertion = SleepAssertion(identifier: 7) { id in released.withLock { $0.append(id) } }
            withExtendedLifetime(assertion) { #expect(released.withLock { $0.isEmpty }) }
        }
        #expect(released.withLock { $0 } == [7])
    }

    @Test func nativeAssertionCanBeAcquiredAndReleased() throws {
        let assertion = try LocalSleepPreventer().acquire()
        assertion.release()
        assertion.release()
    }

    @Test func cancelledTaskDoesNotAcquireNativeAssertion() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(throws: CancellationError.self) { try LocalSleepPreventer().acquire() }
        }
        await task.value
    }
}
