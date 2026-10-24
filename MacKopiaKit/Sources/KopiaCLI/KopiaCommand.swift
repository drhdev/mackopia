import Foundation

/// Initial read-only surface. No arbitrary argument/environment overrides and no config mutation.
enum KopiaCommand: Sendable {
    case repositoryStatus
    case maintenanceInfo
    case snapshotVerify(snapshotIDs: [String], filesPercent: Int)

    var arguments: [String] {
        switch self {
        case .repositoryStatus: ["repository", "status", "--json"]
        case .maintenanceInfo: ["maintenance", "info", "--json"]
        case .snapshotVerify(let ids, let percent):
            ["snapshot", "verify", "--json", "--verify-files-percent=\(percent)"] + ids
        }
    }
}
