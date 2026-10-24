import Foundation

package enum FullDiskAccessObservation: Sendable, Equatable { case readable, denied, unknown }

package protocol FullDiskAccessProbing: Sendable {
    func probe() async throws -> FullDiskAccessObservation
}

/// Must run in the agent. This is evidence of access to protected data, not a TCC database query
/// or proof that a differently signed child process can access every protected source.
package struct LocalFullDiskAccessProbe: FullDiskAccessProbing, CustomReflectable {
    private let home: URL
    private let reader: any ReadAccessProbing

    package init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        reader: any ReadAccessProbing = LocalReadAccessProbe()
    ) {
        self.home = home
        self.reader = reader
    }

    package var customMirror: Mirror { Mirror(self, children: ["protectedAccessProbe": "<private>"]) }

    package func probe() async throws -> FullDiskAccessObservation {
        try Task.checkCancellation()
        let primary = try await reader.readFile(at: home.appendingPathComponent("Library/Safari/Bookmarks.plist").path)
        try Task.checkCancellation()
        switch primary {
        case .readable: return .readable
        case .denied: return .denied
        case .unknown: return .unknown
        case .missing: break
        }
        let fallback = try await reader.readDirectory(at: home.appendingPathComponent("Library/Mail").path)
        try Task.checkCancellation()
        switch fallback {
        case .readable: return .readable
        case .denied: return .denied
        case .missing, .unknown: return .unknown
        }
    }
}
