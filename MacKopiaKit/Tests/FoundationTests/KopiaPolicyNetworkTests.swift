import Foundation
import Testing

@testable import KopiaServer

// Each case owns real child processes; bound concurrent fixture pressure on hosted runners.
@Suite(.serialized)
struct KopiaPolicyNetworkTests {
    private func source() throws -> KopiaSnapshotSource {
        try KopiaSnapshotSource(userName: "user+tag", host: "host+tag", path: "/Source ü + & ? # %2F")
    }

    @Test func authenticatedPolicyReadsUseExactSelectorAndResolveHasNoUpdates() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-read")
        let source = try source()
        #expect(try await fixture.client.policy(source: source)?.retention?.keepLatest == 0)
        let resolved = try await fixture.client.resolvePolicy(source: source)
        #expect(resolved.effective?.retention?.keepLatest == 0)
        #expect(resolved.defined?.retention == nil)
        #expect(fixture.exists("bootstrap-request"))
        #expect(fixture.exists("policy-request"))
        #expect(fixture.exists("policy-resolve-request"))
        for marker in [
            "invalid-policy-selector", "invalid-policy-body", "invalid-auth", "invalid-csrf", "control-request",
        ] {
            #expect(!fixture.exists(marker))
        }
        await fixture.client.close()
        await #expect(throws: KopiaServerClientError.closed) { try await fixture.client.policy(source: source) }
        await #expect(throws: KopiaServerClientError.closed) { try await fixture.client.resolvePolicy(source: source) }
    }

    @Test func onlyExpectedMissingPolicyResponseBecomesNil() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-missing")
        let source = try source()
        #expect(try await fixture.client.policy(source: source) == nil)
        // A NOT_FOUND from another endpoint must not become an absent source policy.
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.resolvePolicy(source: source)
        }
        await #expect(throws: KopiaServerClientError.response) { try await fixture.client.repositoryStatus() }
        await fixture.client.close()
    }

    @Test(arguments: ["policy-wrong-error", "policy-malformed", "policy-http404", "policy-oversized"])
    func malformedOrUnboundedErrorsNeverBecomeMissingPolicies(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let source = try source()
        let expected: KopiaServerClientError = mode == "policy-oversized" ? .responseTooLarge : .response
        await #expect(throws: expected) { try await fixture.client.policy(source: source) }
        await fixture.client.close()
    }

    @Test func cancelledResolveNeverAuthenticatesOrSendsPost() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-read")
        let source = try source()
        let client = fixture.client
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.resolvePolicy(source: source)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!fixture.exists("bootstrap-request"))
        #expect(!fixture.exists("policy-resolve-request"))
        await fixture.client.close()
    }

    @Test(arguments: ["cancel-root", "cancel-api"])
    func activeResolveCancellationClosesConnection(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let source = try source()
        let client = fixture.client
        let request = Task { try await client.resolvePolicy(source: source) }
        defer { request.cancel() }
        try await fixture.waitFor("active")
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        try await fixture.waitFor("peer-closed")
        #expect(!fixture.exists("peer-timeout"))
        await client.close()
    }

    @Test(arguments: ["redirect-same", "redirect-other"])
    func resolveDoesNotFollowRedirects(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let source = try source()
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.resolvePolicy(source: source)
        }
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }
}
