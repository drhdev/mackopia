import Foundation

/// Initial read-only surface. No arbitrary argument/environment overrides and no config mutation.
enum KopiaCommand: Sendable {
    case repositoryStatus
    case maintenanceInfo

    var arguments: [String] {
        switch self {
        case .repositoryStatus: ["repository", "status", "--json"]
        case .maintenanceInfo: ["maintenance", "info", "--json"]
        }
    }
}
