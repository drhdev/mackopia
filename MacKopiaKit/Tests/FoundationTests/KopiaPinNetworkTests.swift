import Foundation
import Testing

@testable import KopiaServer

@Suite(.serialized)
struct KopiaPinNetworkTests {
    @Test func pinUsesAuthenticatedAddOnlyRequestAndReturnsReplacementIdentifier() async throws {
        let fixture = try await KopiaTLSFixture(mode: "pin-success")
        let pinned = try await fixture.client.pinSnapshot(id: "abc123")
        #expect(pinned.id == "def456")
        #expect(pinned.pins == [KopiaServerClient.plausibilityPin])
        #expect(fixture.exists("pin-request"))
        for marker in ["invalid-auth", "invalid-csrf", "invalid-pin-body"] { #expect(!fixture.exists(marker)) }
        await fixture.client.close()
    }

    @Test(arguments: ["pin-empty", "pin-unpinned", "pin-duplicate", "redirect-same", "redirect-other"])
    func malformedResponsesAndRedirectsCannotConfirmPin(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        await #expect(throws: KopiaServerClientError.response) { try await fixture.client.pinSnapshot(id: "abc123") }
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }

    @Test func invalidIdentifiersAreRejectedBeforeAnyConnection() async throws {
        let fixture = try await KopiaTLSFixture(mode: "pin-success")
        for id in ["", "../abc", "abc?token=x", String(repeating: "a", count: 129)] {
            await #expect(throws: KopiaServerClientError.invalidRequest) {
                try await fixture.client.pinSnapshot(id: id)
            }
        }
        #expect(!fixture.exists("bootstrap-request"))
        #expect(!fixture.exists("pin-request"))
        await fixture.client.close()
    }
}
