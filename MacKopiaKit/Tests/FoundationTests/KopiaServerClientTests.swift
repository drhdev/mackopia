import Foundation
import Testing

@testable import KopiaServer

struct KopiaServerClientTests {
    private let address = URL(string: "https://127.0.0.1:12345")

    @Test func csrfRequiresBothCookieAndTokenAndRedactsReflection() throws {
        let address = try #require(address)
        let response = try #require(
            HTTPURLResponse(
                url: address, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "Kopia-Session-Cookie=ephemeral; Path=/; Secure; HttpOnly"]))
        let csrf = try KopiaServerCSRFSession(
            response: response, body: Data("<meta name=\"kopia-csrf-token\" content=\"abcdef0123\">".utf8),
            address: address)
        #expect(csrf.cookie == "ephemeral")
        #expect(csrf.token == "abcdef0123")
        #expect(!String(reflecting: csrf).contains("ephemeral"))
        #expect(!String(reflecting: csrf).contains("abcdef0123"))
        for html in [
            "", "<meta name=\"kopia-csrf-token\" content=\"not-hex\">", "<meta name=\"kopia-csrf-token\" content=\"\">",
        ] {
            #expect(throws: KopiaServerClientError.csrf) {
                try KopiaServerCSRFSession(response: response, body: Data(html.utf8), address: address)
            }
        }
        let noCookie = try #require(HTTPURLResponse(url: address, statusCode: 200, httpVersion: nil, headerFields: [:]))
        #expect(throws: KopiaServerClientError.csrf) {
            try KopiaServerCSRFSession(
                response: noCookie, body: Data("<meta name=\"kopia-csrf-token\" content=\"abc\">".utf8),
                address: address)
        }
    }

    @Test func csrfRejectsOversizedSessionValues() throws {
        let address = try #require(address)
        let response = try #require(
            HTTPURLResponse(
                url: address, statusCode: 200, httpVersion: nil,
                headerFields: ["Set-Cookie": "Kopia-Session-Cookie=value; Path=/"]))
        let html = "<meta name=\"kopia-csrf-token\" content=\"" + String(repeating: "a", count: 4097) + "\">"
        #expect(throws: KopiaServerClientError.csrf) {
            try KopiaServerCSRFSession(response: response, body: Data(html.utf8), address: address)
        }
    }

    @Test func statusDecodingKeepsMissingFieldsUnknownAndIgnoresNewFields() throws {
        let missing = try JSONDecoder().decode(KopiaRepositoryStatus.self, from: Data("{}".utf8))
        #expect(missing.connected == nil)
        #expect(missing.storage == nil)
        let populated = try JSONDecoder().decode(
            KopiaRepositoryStatus.self,
            from: Data(#"{"connected":true,"formatVersion":3,"storage":"filesystem","futureField":42}"#.utf8))
        #expect(populated.connected == true)
        #expect(populated.formatVersion == 3)
        #expect(populated.storage == "filesystem")
    }

    @Test func cancelledRequestDoesNotStartAuthentication() async throws {
        var parser = KopiaServerHandshakeParser()
        let parsed = try parser.consume(KopiaServerHandshakeTests().transcript())
        let handshake = try #require(parsed)
        let client = KopiaServerClient(handshake: handshake)
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.repositoryStatus()
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        await client.close()
    }

    @Test func taskIdentifiersCannotChangeRequestDestinationOrRoute() async throws {
        var parser = KopiaServerHandshakeParser()
        let parsed = try parser.consume(KopiaServerHandshakeTests().transcript())
        let handshake = try #require(parsed)
        let client = KopiaServerClient(handshake: handshake)
        for id in [
            "", ".", "..", "../status", "1?x=y", "1#fragment", "https://example.invalid", "%2f", "1\0", "ä",
            String(repeating: "a", count: 129),
        ] {
            await #expect(throws: KopiaServerClientError.invalidRequest) { try await client.task(id: id) }
        }
        await client.close()
        for id in ["1", "abc_123-XYZ", String(repeating: "a", count: 128)] {
            await #expect(throws: KopiaServerClientError.closed) { try await client.task(id: id) }
        }
        await #expect(throws: KopiaServerClientError.closed) { try await client.sources() }
        await #expect(throws: KopiaServerClientError.closed) { try await client.tasks() }
    }
}
