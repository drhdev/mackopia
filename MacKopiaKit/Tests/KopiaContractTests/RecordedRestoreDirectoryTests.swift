import Foundation
import Testing

@testable import KopiaCLI

@Test func recordedDirectoryPreservesFileSelectionMetadata() throws {
    // Kopia 0.23.1: `show <directory object>` uses the same stored stream as the object REST fixture.
    let directory = try JSONDecoder().decode(KopiaRestoreSampler.Directory.self, from: fixture("rest-object"))
    #expect(directory.stream == "kopia:directory")
    let entries = try #require(directory.entries)
    #expect(entries.map(\.name) == ["empty", "hello.txt"])
    #expect(entries.first?.size == nil)
    #expect(entries.last?.size == 30)
    #expect(entries.allSatisfy { $0.type == "f" && KopiaRestoreSampler.validObjectID($0.obj ?? "") })
    #expect(entries.last?.mtime == "2026-10-23T14:28:08.049510109Z")
}
