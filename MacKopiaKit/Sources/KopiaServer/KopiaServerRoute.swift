import Foundation

/// Only these read-only routes may receive the child process credentials.
enum KopiaServerRoute: Sendable {
    case root, repositoryStatus, sources, tasks
    case task(String)
    case snapshots(KopiaSnapshotSource)
    case directory(String)

    func url(relativeTo base: URL) throws -> URL {
        let path: String
        var query: [URLQueryItem] = []
        switch self {
        case .root: path = ""
        case .repositoryStatus: path = "api/v1/repo/status"
        case .sources: path = "api/v1/sources"
        case .tasks: path = "api/v1/tasks"
        case .task(let id):
            try Self.validateSegment(id, limit: 128)
            path = "api/v1/tasks/" + id
        case .directory(let id):
            try Self.validateSegment(id, limit: 512)
            path = "api/v1/objects/" + id
        case .snapshots(let source):
            path = "api/v1/snapshots"
            query = [
                URLQueryItem(name: "userName", value: source.userName),
                URLQueryItem(name: "host", value: source.host),
                URLQueryItem(name: "path", value: source.path),
            ]
        }
        let url = base.appendingPathComponent(path)
        guard !query.isEmpty else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw KopiaServerClientError.invalidRequest
        }
        components.queryItems = query
        // Kopia 0.23.1: Go query decoding treats literal '+' as space; preserve source identity.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = components.url else { throw KopiaServerClientError.invalidRequest }
        return result
    }

    private static func validateSegment(_ value: String, limit: Int) throws {
        guard !value.isEmpty, value.utf8.count <= limit,
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
            })
        else { throw KopiaServerClientError.invalidRequest }
    }
}
