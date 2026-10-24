import BackupDomain
import Foundation
import Testing

@testable import BackupEngine
@testable import KopiaServer

struct KopiaPolicyDefinitionNetworkTests {
    private func source() throws -> KopiaSnapshotSource {
        try KopiaSnapshotSource(userName: "user+tag", host: "host+tag", path: "/Source ü + & ? # %2F")
    }

    @Test func completeDefinitionPreservesOpaqueValuesAndBindsExactSource() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-definition-read")
        let selector = try source()
        let definition = try #require(try await fixture.client.policyDefinition(source: selector))
        #expect(definition.source == selector)
        #expect(
            definition.source != (try KopiaSnapshotSource(userName: "other", host: selector.host, path: selector.path)))
        let original = try definition.document.encoded()
        // Exercise the actual server-read → engine-merge path without writing any policy.
        let desired = TranslatedSourcePolicy(
            source: try BackupSource(
                path: selector.path,
                volume: VolumeIdentity(uuid: UUID().uuidString, name: "Test", isRemovable: false, isNetwork: false)),
            retention: try RetentionPolicy(keepLatest: 2), compression: .none,
            ignore: [], ignoreCacheDirs: false, maxFileSize: nil, oneFileSystem: true)
        let merged = try SourcePolicyMerger.merge(desired, into: definition.document).encoded()
        for token in [
            #""number":9007199254740993"#, #""huge":184467440737095516160"#,
            #""decimal":1.234567890123456789"#, #""scheduling":{"intervalSeconds":3600}"#,
        ] {
            #expect(String(decoding: original, as: UTF8.self).contains(token))
            #expect(String(decoding: merged, as: UTF8.self).contains(token))
        }
        #expect(!String(reflecting: definition).contains("private pattern"))
        #expect(!String(reflecting: definition).contains(selector.path))
        #expect(fixture.exists("bootstrap-request"))
        #expect(fixture.exists("policy-request"))
        for marker in [
            "invalid-policy-selector", "invalid-auth", "invalid-csrf", "policy-resolve-request", "control-request",
        ] {
            #expect(!fixture.exists(marker))
        }
        await fixture.client.close()
        await #expect(throws: KopiaServerClientError.closed) {
            try await fixture.client.policyDefinition(source: selector)
        }
    }

    @Test(arguments: ["policy-missing", "policy-wrong-error", "policy-malformed", "policy-http404", "policy-oversized"])
    func missingDefinitionRequiresExactError(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let selector = try source()
        if mode == "policy-missing" {
            #expect(try await fixture.client.policyDefinition(source: selector) == nil)
        } else {
            let expected: KopiaServerClientError = mode == "policy-oversized" ? .responseTooLarge : .response
            await #expect(throws: expected) { try await fixture.client.policyDefinition(source: selector) }
        }
        await fixture.client.close()
    }

    @Test(arguments: ["array", "null", "malformed", "duplicate", "section", "type", "depth"])
    func invalidCompleteDocumentsAreRejected(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-definition-" + mode)
        let selector = try source()
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.policyDefinition(source: selector)
        }
        await fixture.client.close()
    }

    @Test(arguments: ["exact", "declared", "chunked"])
    func completeDefinitionHasOneMiBStreamingLimit(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-definition-" + mode)
        let selector = try source()
        if mode == "exact" {
            let definition = try #require(try await fixture.client.policyDefinition(source: selector))
            #expect(try definition.document.encoded().count == KopiaPolicyDocument.maximumBytes)
        } else {
            await #expect(throws: KopiaServerClientError.responseTooLarge) {
                try await fixture.client.policyDefinition(source: selector)
            }
        }
        await fixture.client.close()
    }

    @Test func cancelledDefinitionNeverAuthenticates() async throws {
        let fixture = try await KopiaTLSFixture(mode: "policy-missing")
        let selector = try source()
        let client = fixture.client
        let request = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.policyDefinition(source: selector)
        }
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(!fixture.exists("bootstrap-request"))
        #expect(!fixture.exists("policy-request"))
        await client.close()
    }

    @Test(arguments: ["cancel-root", "cancel-api"])
    func activeDefinitionCancellationClosesConnection(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let selector = try source()
        let client = fixture.client
        let request = Task { try await client.policyDefinition(source: selector) }
        defer { request.cancel() }
        try await fixture.waitFor("active")
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        try await fixture.waitFor("peer-closed")
        await fixture.client.close()
    }

    @Test(arguments: ["redirect-same", "redirect-other"])
    func definitionNeverFollowsRedirects(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        let selector = try source()
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.policyDefinition(source: selector)
        }
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }
}
