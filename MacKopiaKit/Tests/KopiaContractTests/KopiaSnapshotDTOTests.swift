import Foundation
import Testing

@testable import KopiaServer

@Test func nativeSnapshotListDecodesRecordedRootsAndSummaries() throws {
    let decoder = JSONDecoder()
    let list = try decoder.decode(KopiaSnapshots.self, from: fixture("rest-snapshots"))
    #expect(list.unfilteredCount == 2)
    #expect(list.uniqueCount == 2)
    let snapshots = try #require(list.snapshots)
    #expect(snapshots.count == 2)
    let latest = try #require(snapshots.max { ($0.startTime ?? "") < ($1.startTime ?? "") })
    #expect(latest.rootID == "k894b01a4f99ca3cc3dbdbd812055e67b")
    #expect(latest.summary?.size == 30)
    #expect(latest.summary?.files == 2)
    #expect(latest.retention?.contains("latest-1") == true)
    #expect(latest.pins?.isEmpty == true)
    let cancelled = try decoder.decode(KopiaSnapshots.self, from: fixture("cancel-snapshots"))
    #expect(cancelled.snapshots?.contains { $0.incomplete == "canceled" } == true)
}

@Test func nativeDirectoryDecodesRecordedEntriesWithoutInventingFileSizes() throws {
    let directory = try JSONDecoder().decode(KopiaDirectory.self, from: fixture("rest-object"))
    #expect(directory.stream == "kopia:directory")
    #expect(directory.summary?.size == 30)
    #expect(directory.summary?.numFailed == 0)
    let entries = try #require(directory.entries)
    #expect(entries.count == 2)
    let file = try #require(entries.first { $0.name == "hello.txt" })
    #expect(file.type == "f")
    #expect(file.size == 30)
    #expect(file.mode == "0644")
    #expect(file.obj == "41e7d25f3a66f5ba81691a1171cd8517")
    let empty = try #require(entries.first { $0.name == "empty" })
    #expect(empty.size == nil)
    #expect(!String(reflecting: directory).contains("hello.txt"))
    #expect(!String(reflecting: file).contains("hello.txt"))
}

@Test func nativeBrowseDTOsKeepUnknownValuesAndRejectMalformedKnownFields() throws {
    let decoder = JSONDecoder()
    let snapshots = try decoder.decode(
        KopiaSnapshots.self, from: Data(#"{"snapshots":[{"future":42,"incomplete":"future-reason"}]}"#.utf8))
    #expect(snapshots.snapshots?.first?.incomplete == "future-reason")
    #expect(snapshots.snapshots?.first?.rootID == nil)
    #expect(snapshots.uniqueCount == nil)
    let directory = try decoder.decode(
        KopiaDirectory.self,
        from: Data(
            #"{"stream":"future-stream","entries":[{"name":"../untrusted","type":"future","size":5000000000}]}"#.utf8))
    #expect(directory.stream == "future-stream")
    #expect(directory.entries?.first?.type == "future")
    #expect(directory.entries?.first?.size == 5_000_000_000)
    #expect(directory.summary == nil)
    #expect(throws: DecodingError.self) {
        try decoder.decode(KopiaSnapshots.self, from: Data(#"{"snapshots":{}}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(KopiaDirectory.self, from: Data(#"{"entries":[{"size":"broken"}]}"#.utf8))
    }
}
