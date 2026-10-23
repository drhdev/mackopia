import Foundation

/// Derive every service name from the signed application's bundle identifier.
public struct AgentServiceIdentity: Sendable, Equatable {
    public let appBundleID: String
    public var agentBundleID: String { appBundleID + ".Agent" }
    public var machServiceName: String { agentBundleID + ".xpc" }
    public var plistName: String { agentBundleID + ".plist" }

    public init(appBundleID: String) throws {
        let segments = appBundleID.split(separator: ".", omittingEmptySubsequences: false)
        // bootstrap.h reserves 128 bytes including the terminating NUL.
        guard (appBundleID + ".Agent.xpc").utf8.count < 128, segments.count >= 2,
            segments.allSatisfy({ segment in
                !segment.isEmpty
                    && segment.utf8.allSatisfy {
                        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                    }
            })
        else { throw AgentServiceError.invalidIdentity }
        self.appBundleID = appBundleID
    }
}
