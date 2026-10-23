import BackupEngine
import Foundation
import Testing

struct RepositoryOperationGateTests {
    @Test func defaultLimitRejectsOtherRepositoriesAndSameRepositoryHasPriority() async throws {
        let gate = try RepositoryOperationGate()
        let id = UUID()
        let entered = OperationSignal()
        let finish = OperationSignal()
        let running = Task {
            try await gate.withOperation(repositoryID: id) {
                await entered.signal()
                await finish.wait()
                return 42
            }
        }
        await entered.wait()
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: id) { Issue.record("Busy operation entered") }
        }
        await #expect(throws: RepositoryOperationError.concurrencyLimitReached) {
            try await gate.withOperation(repositoryID: UUID()) { Issue.record("Global limit exceeded") }
        }
        await finish.signal()
        #expect(try await running.value == 42)
        #expect(try await gate.withOperation(repositoryID: id) { 7 } == 7)
    }

    @Test func independentRepositoriesCanOverlapButBackupAndMaintenanceCannotShareOne() async throws {
        let gate = try RepositoryOperationGate(maximumConcurrentOperations: 2)
        let firstID = UUID()
        let secondID = UUID()
        let firstEntered = OperationSignal()
        let secondEntered = OperationSignal()
        let finish = OperationSignal()
        let first = Task {
            try await gate.withOperation(repositoryID: firstID) {
                await firstEntered.signal()
                await finish.wait()
            }
        }
        await firstEntered.wait()
        let second = Task {
            try await gate.withOperation(repositoryID: secondID) {
                await secondEntered.signal()
                await finish.wait()
            }
        }
        await secondEntered.wait()
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: firstID) { Issue.record("Maintenance entered during backup") }
        }
        await #expect(throws: RepositoryOperationError.concurrencyLimitReached) {
            try await gate.withOperation(repositoryID: UUID()) { Issue.record("Third operation entered") }
        }
        await finish.signal()
        try await first.value
        try await second.value
    }

    @Test func failureAndNestedRejectionAlwaysReleaseAdmission() async throws {
        let gate = try RepositoryOperationGate()
        let id = UUID()
        let nestedOperation: @Sendable () async throws -> Void = {
            await #expect(throws: RepositoryOperationError.repositoryBusy) {
                try await gate.withOperation(repositoryID: id) { Issue.record("Nested operation entered") }
            }
            throw TestFailure.failed
        }
        await #expect(throws: TestFailure.failed) {
            try await gate.withOperation(repositoryID: id, operation: nestedOperation)
        }
        #expect(try await gate.withOperation(repositoryID: id) { true })
    }

    @Test func cancellationRetainsExclusionUntilOperationCleanupFinishes() async throws {
        let gate = try RepositoryOperationGate()
        let id = UUID()
        let entered = OperationSignal()
        let cleanup = OperationSignal()
        let running = Task {
            try await gate.withOperation(repositoryID: id) {
                await entered.signal()
                // Simulates a process lifecycle that must finish reaping even after cancellation.
                await cleanup.wait()
                try Task.checkCancellation()
            }
        }
        await entered.wait()
        running.cancel()
        await #expect(throws: RepositoryOperationError.repositoryBusy) {
            try await gate.withOperation(repositoryID: id) { Issue.record("Entered before cleanup finished") }
        }
        await cleanup.signal()
        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(try await gate.withOperation(repositoryID: id) { true })
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await #expect(throws: CancellationError.self) {
                try await gate.withOperation(repositoryID: id) { Issue.record("Cancelled operation entered") }
            }
        }
        await cancelled.value
        #expect(try await gate.withOperation(repositoryID: id) { true })
    }

    @Test func invalidLimitsAreRejected() {
        for limit in [0, -1, Int.min] {
            #expect(throws: RepositoryOperationError.invalidLimit) {
                try RepositoryOperationGate(maximumConcurrentOperations: limit)
            }
        }
    }

    private enum TestFailure: Error { case failed }
}

private actor OperationSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
