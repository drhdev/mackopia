import Foundation

struct KopiaServerCSRFSession: Sendable, CustomReflectable {
    let cookie: String
    let token: String
    var customMirror: Mirror { Mirror(self, children: [:]) }

    init(response: HTTPURLResponse, body: Data, address: URL) throws {
        guard let html = String(data: body, encoding: .utf8),
            let match = html.firstMatch(of: /<meta name="kopia-csrf-token" content="([0-9a-f]+)"/)
        else { throw KopiaServerClientError.csrf }
        let token = String(match.1)
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, item in
            if let name = item.key as? String, let value = item.value as? String { result[name] = value }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: address)
            .filter { $0.name == "Kopia-Session-Cookie" }
        guard cookies.count == 1, let cookie = cookies.first,
            !cookie.value.isEmpty, cookie.value.utf8.count <= 4096,
            cookie.value.utf8.allSatisfy({ (33...126).contains($0) && $0 != 59 && $0 != 44 }),
            !token.isEmpty, token.utf8.count <= 4096
        else { throw KopiaServerClientError.csrf }
        self.cookie = cookie.value
        self.token = token
    }
}
