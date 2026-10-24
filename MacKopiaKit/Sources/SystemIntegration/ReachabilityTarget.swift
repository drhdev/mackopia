import Foundation

/// Nonsecret destination metadata only; reflection still hides the user's host name.
package struct ReachabilityTarget: Sendable, Hashable, CustomReflectable {
    package let host: String
    package let port: UInt16
    package let prohibitExpensivePaths: Bool
    package let prohibitConstrainedPaths: Bool

    package init?(host: String, port: Int, prohibitExpensivePaths: Bool = false, prohibitConstrainedPaths: Bool = false)
    {
        let host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !host.isEmpty, host.utf8.count <= 1024,
            !host.contains(where: { $0.isWhitespace || "/\\?#@[]".contains($0) }),
            !host.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
            let port = UInt16(exactly: port), port > 0
        else { return nil }
        self.host = host
        self.port = port
        self.prohibitExpensivePaths = prohibitExpensivePaths
        self.prohibitConstrainedPaths = prohibitConstrainedPaths
    }

    package var customMirror: Mirror { Mirror(self, children: ["destination": "<private>"]) }
}

package protocol DestinationReachabilityChecking: Sendable {
    /// TCP establishment only, with no application data or credentials; cancellation joins cleanup.
    func canConnect(to target: ReachabilityTarget) async throws -> Bool
}
