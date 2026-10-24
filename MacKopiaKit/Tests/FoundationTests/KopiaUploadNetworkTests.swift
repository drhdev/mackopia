import Foundation
import Testing

@testable import KopiaServer

// Each case owns real child processes; bound concurrent fixture pressure on hosted runners.
@Suite(.serialized)
struct KopiaUploadNetworkTests {
    private func source() throws -> KopiaSnapshotSource {
        try KopiaSnapshotSource(userName: "user+tag", host: "host+tag", path: "/Source ü + & ? # %2F")
    }

    @Test func uploadAndCancelUsePinnedAuthenticatedExactSourceAndValidateAcknowledgment() async throws {
        let fixture = try await KopiaTLSFixture(mode: "upload-success")
        try await fixture.client.startUpload(source: source())
        try await fixture.client.cancelUpload(source: source())
        #expect(fixture.exists("upload-request"))
        #expect(fixture.exists("cancel-request"))
        for name in ["invalid-auth", "invalid-csrf", "invalid-upload-body", "invalid-upload-selector"] {
            #expect(!fixture.exists(name))
        }
        await fixture.client.close()
    }

    @Test(arguments: [
        "upload-rejected", "upload-empty", "upload-foreign", "upload-extra", "redirect-same", "redirect-other",
    ])
    func invalidAcknowledgmentsAndRedirectsNeverImplyUploadAcceptance(mode: String) async throws {
        let fixture = try await KopiaTLSFixture(mode: mode)
        await #expect(throws: KopiaServerClientError.response) {
            try await fixture.client.startUpload(source: source())
        }
        #expect(!fixture.exists("redirect-followed"))
        await fixture.client.close()
    }

    @Test func manifestListingIncludesIdenticalBackups() throws {
        let selector = try source()
        let url = try KopiaServerRoute.snapshotManifests(selector).url(
            relativeTo: #require(URL(string: "https://127.0.0.1:1234")))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)).queryItems
        #expect(query?.first { $0.name == "all" }?.value == "true")
        #expect(query?.first { $0.name == "path" }?.value == selector.path)
    }
}
