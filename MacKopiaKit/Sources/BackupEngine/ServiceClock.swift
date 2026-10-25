import Foundation

/// Preserve the monotonic instant while allowing the service's composed runtime to use virtual time.
struct ServiceClock: Clock {
    typealias Instant = ContinuousClock.Instant
    typealias Duration = Swift.Duration
    private let instant: @Sendable () -> Instant
    private let resolution: Duration
    private let suspend: @Sendable (Instant, Duration?) async throws -> Void

    init<C: Clock>(_ clock: C) where C.Instant == Instant, C.Duration == Duration {
        instant = { clock.now }
        resolution = clock.minimumResolution
        suspend = { try await clock.sleep(until: $0, tolerance: $1) }
    }
    var now: Instant { instant() }
    var minimumResolution: Duration { resolution }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws { try await suspend(deadline, tolerance) }
}
