import Foundation
import Testing

@testable import KopiaServer

struct KopiaServerNetworkTests {
    @Test func controlRejectsAuthenticationFailureAndRedirect() async throws {
        for mode in ["control-denied", "control-redirect"] {
            let fixture = try await KopiaTLSFixture(mode: mode)
            let expected: KopiaServerClientError = mode == "control-denied" ? .authentication : .response
            await #expect(throws: expected) { try await fixture.client.shutdownServer() }
            #expect(fixture.exists("control-request"))
            #expect(!fixture.exists("invalid-control"))
            #expect(!fixture.exists("redirect-followed"))
            #expect(!fixture.exists("bootstrap-request"))
            await fixture.client.close()
        }
    }

    @Test func cancelledControlDoesNotSendRequest() async throws {
        let fixture = try await KopiaTLSFixture(mode: "exact")
        let client = fixture.client
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await client.shutdownServer()
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!fixture.exists("control-request"))
        #expect(!fixture.exists("bootstrap-request"))
        await client.close()
    }

    @Test(arguments: [false, true])
    func controlUsesSeparateCredentialsWithoutCSRF(bootstrapFirst: Bool) async throws {
        let fixture = try await KopiaTLSFixture(mode: "exact")
        if bootstrapFirst { _ = try await fixture.client.repositoryStatus() }
        try await fixture.client.shutdownServer()
        #expect(fixture.exists("control-request"))
        #expect(!fixture.exists("invalid-control"))
        #expect(fixture.exists("bootstrap-request") == bootstrapFirst)
        await fixture.client.close()
        await #expect(throws: KopiaServerClientError.closed) { try await fixture.client.shutdownServer() }
    }

    @Test(arguments: ["declared", "streamed", "root-declared"])
    func rejectsOversizedResponses(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        await #expect(throws: KopiaServerClientError.responseTooLarge) { try await fixture.client.repositoryStatus() }
        if mode != "streamed" { try await fixture.waitFor("peer-closed") }
        #expect(!fixture.exists("invalid-auth"))
        #expect(!fixture.exists("invalid-csrf"))
        await fixture.client.close()
    }

    @Test func acceptsResponseExactlyAtLimit() async throws {
        let fixture = try await KopiaTLSFixture(mode: "exact")
        let status = try await fixture.client.repositoryStatus()
        #expect(status.connected == false)
        await fixture.client.close()
    }

    @Test(arguments: ["redirect-same", "redirect-other"])
    func doesNotFollowRedirects(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        await #expect(throws: KopiaServerClientError.response) { try await fixture.client.repositoryStatus() }
        #expect(fixture.exists("redirect-sent"))
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }

    @Test(arguments: ["cancel-root", "cancel-api"])
    func cancellationClosesActiveConnection(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let client = fixture.client
        let request = Task { try await client.repositoryStatus() }
        defer { request.cancel() }
        try await fixture.waitFor("active")
        let start = ContinuousClock.now
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(ContinuousClock.now - start < .seconds(3))
        try await fixture.waitFor("peer-closed")
        #expect(!fixture.exists("peer-timeout"))
        await client.close()
    }
}
