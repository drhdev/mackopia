import Foundation

/// Kopia 0.23.1: an empty verify target would verify the entire repository. Admit exact manifests only.
package struct KopiaSnapshotVerification: Sendable {
    let snapshotIDs: [String]
    let filesPercent: Int

    package init(snapshotIDs: [String], filesPercent: Int) throws {
        guard (1...100).contains(filesPercent), (1...1024).contains(snapshotIDs.count),
            Set(snapshotIDs).count == snapshotIDs.count,
            snapshotIDs.allSatisfy({
                $0.utf8.count == 32 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            })
        else { throw KopiaProcessError.invalidRequest }
        self.snapshotIDs = snapshotIDs
        self.filesPercent = filesPercent
    }
}
