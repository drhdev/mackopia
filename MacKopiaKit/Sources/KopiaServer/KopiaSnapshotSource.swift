import Foundation

/// A complete source identity; never broaden an incomplete selector to all snapshots.
struct KopiaSnapshotSource: Sendable, CustomReflectable {
    let userName: String
    let host: String
    let path: String

    init(userName: String, host: String, path: String) throws {
        guard Self.valid(userName, limit: 1024), Self.valid(host, limit: 1024),
            Self.valid(path, limit: 16_384), path.hasPrefix("/")
        else { throw KopiaServerClientError.invalidRequest }
        self.userName = userName
        self.host = host
        self.path = path
    }

    var customMirror: Mirror { Mirror(self, children: ["source": "<private>"]) }

    private static func valid(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && !value.utf8.contains(0)
    }
}
