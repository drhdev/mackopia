import BackupDomain
import Foundation
import SystemIntegration

package enum DestinationTriggerMapping {
    package static func matches(volumeUUID: String, plan: BackupPlan, repository: Repository) -> Bool {
        if plan.sources.contains(where: { $0.volume.uuid == volumeUUID }) { return true }
        if case .filesystem(_, let volume) = repository.kind { return volume?.uuid == volumeUUID }
        return false
    }

    package static func networkTarget(repository: Repository, conditions: RunConditions) -> ReachabilityTarget? {
        let host: String
        let port: Int
        switch repository.kind {
        case .sftp(let name, let number, _, _, _, _):
            host = name
            port = number
        case .webdav(let url):
            guard let pair = address(url, schemes: ["http": 80, "https": 443]) else { return nil }
            (host, port) = pair
        case .s3(let endpoint, _, _, _, _):
            guard let url = URL(string: endpoint), let pair = address(url, schemes: ["http": 80, "https": 443]) else {
                return nil
            }
            (host, port) = pair
        case .filesystem(_, let volume):
            guard let url = volume?.remountURL, let pair = address(url, schemes: ["smb": 445]) else { return nil }
            (host, port) = pair
        }
        return ReachabilityTarget(
            host: host, port: port, prohibitExpensivePaths: conditions.skipOnExpensiveNetwork,
            prohibitConstrainedPaths: conditions.skipOnConstrainedNetwork)
    }

    private static func address(_ url: URL, schemes: [String: Int]) -> (String, Int)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), let defaultPort = schemes[scheme],
            let host = components.host
        else { return nil }
        if components.rangeOfPort != nil, components.port == nil { return nil }
        return (host, components.port ?? defaultPort)
    }
}
