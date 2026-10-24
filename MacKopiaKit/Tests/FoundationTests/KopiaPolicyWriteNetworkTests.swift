import Foundation
import Testing

@testable import KopiaServer

// Each case owns real child processes; bound concurrent fixture pressure on hosted runners.
@Suite(.serialized)
struct KopiaPolicyWriteNetworkTests {
    private func source() throws -> KopiaSnapshotSource {
        try KopiaSnapshotSource(userName: "user+tag", host: "host+tag", path: "/Source ü + & ? # %2F")
    }

    @Test func previewDoesNotPersistAndPutUsesPinnedAuthenticatedExactSource() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-write")
        let selector = try source()
        let candidate = try KopiaPolicyDocument(
            data: Data(#"{"files":{"ignore":["private pattern"]},"retention":{"keepLatest":0}}"#.utf8))
        let preview = try await fixture.client.previewPolicy(source: selector, updates: candidate)
        #expect(try preview.equivalent(to: candidate))
        let before = try #require(try await fixture.client.policyDefinition(source: selector))
        #expect(try before.document.equivalent(to: KopiaPolicyDocument()))
        #expect(!fixture.exists("policy-write-request"))
        try await fixture.client.replacePolicy(source: selector, document: candidate)
        let after = try #require(try await fixture.client.policyDefinition(source: selector))
        #expect(try after.document.equivalent(to: candidate))
        #expect(try await fixture.client.previewPolicy(source: selector, updates: nil).equivalent(to: candidate))
        for marker in [
            "invalid-policy-selector", "invalid-policy-body", "invalid-auth", "invalid-csrf", "control-request",
        ] {
            #expect(!fixture.exists(marker))
        }
        #expect(fixture.exists("bootstrap-request"))
        #expect(fixture.exists("policy-write-request"))
        await fixture.client.close()
        await #expect(throws: KopiaServerClientError.closed) {
            try await fixture.client.replacePolicy(source: selector, document: candidate)
        }
    }

    @Test(arguments: ["redirect-same", "redirect-other"])
    func writesNeverFollowRedirects(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let selector = try source()
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.replacePolicy(source: selector, document: KopiaPolicyDocument())
        }
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }

    @Test func cancelledWriteClosesConnectionAndIsNotRetried() async throws {
        let fixture = try await KopiaTLSFixture(mode: "cancel-api")
        let client = fixture.client
        let selector = try source()
        let task = Task { try await client.replacePolicy(source: selector, document: KopiaPolicyDocument()) }
        defer { task.cancel() }
        try await fixture.waitFor("active")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await fixture.waitFor("peer-closed")
        #expect(!fixture.exists("peer-timeout"))
        await client.close()
    }
}
