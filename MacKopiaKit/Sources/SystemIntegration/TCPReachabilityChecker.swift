import Foundation
import Network

package struct TCPReachabilityChecker: DestinationReachabilityChecking {
    private let clock: any Clock<Duration>
    private let connect: @Sendable (ReachabilityTarget) async throws -> Void

    package init() {
        clock = ContinuousClock()
        connect = Self.connect
    }

    init(clock: any Clock<Duration>, connect: @escaping @Sendable (ReachabilityTarget) async throws -> Void) {
        self.clock = clock
        self.connect = connect
    }

    package func canConnect(to target: ReachabilityTarget) async throws -> Bool {
        try Task.checkCancellation()
        do {
            let result = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    try await connect(target); return true
                }
                group.addTask {
                    try await clock.sleep(for: .seconds(5)); return false
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            return result
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return false
        }
    }

    private static func connect(_ target: ReachabilityTarget) async throws {
        guard let port = NWEndpoint.Port(rawValue: target.port) else { throw POSIXError(.EINVAL) }
        let parameters = NWParametersBuilder { TCP().connectionTimeout(5) }
        parameters.parameters.prohibitExpensivePaths = target.prohibitExpensivePaths
        parameters.parameters.prohibitConstrainedPaths = target.prohibitConstrainedPaths
        let connection = NetworkConnection(
            to: .hostPort(host: NWEndpoint.Host(target.host), port: port),
            using: parameters)
        // End-of-stream initiates TCP establishment, sends no application bytes and closes our write side.
        // The connection belongs to this child task; leaving/cancelling it closes the transport.
        try await connection.send(Data(), endOfStream: true)
    }
}
