import Foundation

package enum SystemEvent: Sendable, Equatable {
    case woke, clockChanged, timeZoneChanged
    case volumeMounted(uuid: String), volumeUnmounted(uuid: String)
    case power(PowerStateObservation)
    case network(SystemNetworkObservation)
}

/// Path availability does not attest that a configured destination is reachable or authenticated.
package struct SystemNetworkObservation: Sendable, Equatable {
    package enum Interface: Sendable, Hashable { case wifi, ethernet, cellular, loopback, other }
    package let isAvailable: Bool
    package let path: NetworkPathObservation
    package let interfaces: Set<Interface>

    package init(isAvailable: Bool, path: NetworkPathObservation, interfaces: Set<Interface>) {
        self.isAvailable = isAvailable
        self.path = isAvailable ? path : NetworkPathObservation()
        self.interfaces = interfaces
    }
}

package protocol SystemEventMonitoring: Sendable {
    /// Owns observers until cancellation. Return only after observers and child tasks are cleaned up.
    func observe(deliver: @escaping @Sendable (SystemEvent) async -> Void) async throws
}

package enum SystemMonitoringError: Error, LocalizedError, CustomDebugStringConvertible {
    case unavailable
    package var errorDescription: String? {
        String(localized: "Systemänderungen können nicht beobachtet werden.")
    }
    package var debugDescription: String { "System event observation unavailable" }
}
