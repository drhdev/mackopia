import Network

/// A fresh path observation, not a reachability or authenticated destination-access check.
package struct LocalNetworkPathSampler: NetworkPathSampling {
    private let clock: any Clock<Duration>
    private let firstPath: @Sendable () async throws -> NetworkPathObservation

    package init() {
        clock = ContinuousClock()
        firstPath = Self.observeFirstPath
    }

    init(
        clock: any Clock<Duration>,
        firstPath: @escaping @Sendable () async throws -> NetworkPathObservation
    ) {
        self.clock = clock
        self.firstPath = firstPath
    }

    package func sampleNetwork() async throws -> NetworkPathObservation {
        try Task.checkCancellation()
        let result = try await withThrowingTaskGroup(of: NetworkPathObservation.self) { group in
            group.addTask { try await firstPath() }
            group.addTask {
                try await clock.sleep(for: .seconds(5))
                return NetworkPathObservation()
            }
            defer { group.cancelAll() }
            return try await group.next() ?? NetworkPathObservation()
        }
        try Task.checkCancellation()
        return result
    }

    private static func observeFirstPath() async throws -> NetworkPathObservation {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            for await path in monitor {
                try Task.checkCancellation()
                // An unsatisfied/requires-connection path cannot attest that the next connection is unmetered.
                return NetworkPathObservation(
                    isSatisfied: path.status == .satisfied,
                    isExpensive: path.isExpensive, isConstrained: path.isConstrained)
            }
            try Task.checkCancellation()
            return NetworkPathObservation()
        } onCancel: {
            monitor.cancel()
        }
    }
}
