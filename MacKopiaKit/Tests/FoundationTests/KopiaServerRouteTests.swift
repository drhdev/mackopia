import Foundation
import Testing

@testable import KopiaServer

struct KopiaServerRouteTests {
    @Test func snapshotQueryPreservesCompleteSourceIdentity() throws {
        let base = try #require(URL(string: "https://127.0.0.1:12345"))
        let source = try KopiaSnapshotSource(
            userName: "name+tag&host=evil", host: "host?#%+", path: "/Quelle ü + & ? # %2F/資料")
        let url = try KopiaServerRoute.snapshots(source).url(relativeTo: base)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 12345)
        #expect(url.path == "/api/v1/snapshots")
        #expect(components.fragment == nil)
        #expect(components.queryItems?.count == 3)
        #expect(components.queryItems?.first { $0.name == "userName" }?.value == source.userName)
        #expect(components.queryItems?.first { $0.name == "host" }?.value == source.host)
        #expect(components.queryItems?.first { $0.name == "path" }?.value == source.path)
        #expect(components.percentEncodedQuery?.contains("+") == false)
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        for (route, path) in [
            (KopiaServerRoute.policy(source), "/api/v1/policy"),
            (.resolvePolicy(source), "/api/v1/policy/resolve"),
        ] {
            let policyURL = try route.url(relativeTo: base)
            let policyQuery = try #require(URLComponents(url: policyURL, resolvingAgainstBaseURL: false))
            #expect(policyURL.path == path)
            #expect(policyQuery.queryItems == components.queryItems)
            #expect(policyQuery.percentEncodedQuery == components.percentEncodedQuery)
        }
        #expect(!String(reflecting: source).contains("Quelle"))
    }

    @Test func rejectsIncompleteOrOversizedSourceIdentities() throws {
        for (user, host, path) in [
            ("", "host", "/source"), ("user", "", "/source"), ("user", "host", ""),
            ("user", "host", "relative"), ("user\0", "host", "/source"),
            ("user", "host\0", "/source"), ("user", "host", "/source\0"),
            (String(repeating: "x", count: 1025), "host", "/source"),
            ("user", String(repeating: "x", count: 1025), "/source"),
            ("user", "host", "/" + String(repeating: "x", count: 16_384)),
        ] {
            #expect(throws: KopiaServerClientError.invalidRequest) {
                try KopiaSnapshotSource(userName: user, host: host, path: path)
            }
        }
    }

    @Test func objectIdentifiersAreBoundedSingleSegments() throws {
        let base = try #require(URL(string: "https://127.0.0.1:12345"))
        for id in [
            "", ".", "..", "../other", "x?query", "x#fragment", "%2f", "ü", "a\0", String(repeating: "a", count: 513),
        ] {
            #expect(throws: KopiaServerClientError.invalidRequest) {
                try KopiaServerRoute.directory(id).url(relativeTo: base)
            }
        }
        for id in ["k64064ebd5e441615a4deda46c5584996", "abc_123-XYZ", String(repeating: "a", count: 512)] {
            let url = try KopiaServerRoute.directory(id).url(relativeTo: base)
            #expect(url.path == "/api/v1/objects/" + id)
            #expect(url.query == nil)
        }
    }
}
