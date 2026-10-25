import Foundation

/// Typed repository operations; no arbitrary overrides or config mutation.
enum KopiaCommand: Sendable {
    case repositoryStatus
    case repositoryAccess
    case maintenanceInfo
    case maintenanceFull
    case snapshotVerify(snapshotIDs: [String], filesPercent: Int)
    case showObject(String)
    case restoreSample(objectID: String, destination: String)

    var arguments: [String] {
        switch self {
        case .repositoryAccess: ["blob", "show", "kopia.repository"]
        case .repositoryStatus: ["repository", "status", "--json"]
        case .maintenanceInfo: ["maintenance", "info", "--json"]
        case .maintenanceFull: ["maintenance", "run", "--full"]
        case .snapshotVerify(let ids, let percent):
            ["snapshot", "verify", "--json", "--verify-files-percent=\(percent)"] + ids
        case .showObject(let id): ["show", id]
        case .restoreSample(let id, let destination):
            [
                "snapshot", "restore", id, destination, "--no-overwrite-files", "--no-overwrite-directories",
                "--no-overwrite-symlinks", "--write-files-atomically", "--skip-permissions", "--skip-owners",
                "--skip-times",
            ]
        }
    }
}
