import Foundation
import Testing

private struct RecordedSnapshot: Decodable {
    struct Source: Decodable, Equatable {
        let host: String
        let userName: String
        let path: String
    }

    struct Entry: Decodable {
        let obj: String
    }

    let id: String
    let source: Source
    let rootEntry: Entry
}

func fixture(_ name: String) throws -> Data {
    let resources = try #require(Bundle.module.resourceURL)
    return try Data(contentsOf: resources.appending(path: "Fixtures/kopia-0.23.1/\(name).json"))
}

@Test func recordedCreateAndListAgree() throws {
    let decoder = JSONDecoder()
    let created = try decoder.decode(RecordedSnapshot.self, from: fixture("cli-snapshot-create"))
    let listed = try decoder.decode([RecordedSnapshot].self, from: fixture("cli-snapshot-list"))
    let snapshot = try #require(listed.first)
    #expect(listed.count == 1)
    #expect(snapshot.id == created.id)
    #expect(snapshot.source == created.source)
    #expect(snapshot.rootEntry.obj == created.rootEntry.obj)
    #expect(snapshot.source.path == "/fixture/source")
    #expect(snapshot.source.host == "test-host")
    #expect(snapshot.source.userName == "test-user")
}

@Test func recordedFixturesContainNoMachinePaths() throws {
    let resources = try #require(Bundle.module.resourceURL)
    let directory = resources.appending(path: "Fixtures/kopia-0.23.1")
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    #expect(!files.isEmpty)
    for file in files where file.pathExtension == "json" {
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/Volumes/"))
        #expect(!text.contains("/var/folders/"))
        #expect(!text.contains("/private/var/"))
        #expect(!text.contains("Kopia-Session-Cookie"))
        #expect(!text.contains("SERVER PASSWORD:"))
        #expect(!text.contains("KOPIA_PASSWORD"))
    }
}
