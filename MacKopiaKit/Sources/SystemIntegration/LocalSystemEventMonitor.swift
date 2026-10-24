import Foundation
import Network

/// Structured ownership: cancelling the observation joins both streams and closes native registrations.
package struct LocalSystemEventMonitor: SystemEventMonitoring {
    private let openNative: @Sendable () async throws -> NativeSystemEventSession

    package init() { openNative = { try await NativeSystemEventSession() } }

    init(openNative: @escaping @Sendable () async throws -> NativeSystemEventSession) {
        self.openNative = openNative
    }

    package func observe(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws {
        try Task.checkCancellation()
        let native = try await openNative()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await event in native.events {
                        try Task.checkCancellation()
                        await deliver(event)
                    }
                    try Task.checkCancellation()
                    throw SystemMonitoringError.unavailable
                }
                group.addTask { try await Self.observeNetwork(deliver: deliver) }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            await native.close()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
        await native.close()
    }

    private static func observeNetwork(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws {
        let monitor = NWPathMonitor()
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            var previous: SystemNetworkObservation?
            for await path in monitor {
                try Task.checkCancellation()
                let interfaces: Set<SystemNetworkObservation.Interface> = Set(
                    path.availableInterfaces.filter { path.usesInterfaceType($0.type) }.map {
                        switch $0.type {
                        case .wifi: .wifi
                        case .wiredEthernet: .ethernet
                        case .cellular: .cellular
                        case .loopback: .loopback
                        default: .other
                        }
                    })
                let observation = SystemNetworkObservation(
                    isAvailable: path.status == .satisfied,
                    path: NetworkPathObservation(
                        isSatisfied: path.status == .satisfied,
                        isExpensive: path.isExpensive, isConstrained: path.isConstrained),
                    interfaces: interfaces)
                if previous != observation {
                    previous = observation
                    await deliver(.network(observation))
                }
            }
            try Task.checkCancellation()
            throw SystemMonitoringError.unavailable
        } onCancel: {
            monitor.cancel()
        }
    }
}
