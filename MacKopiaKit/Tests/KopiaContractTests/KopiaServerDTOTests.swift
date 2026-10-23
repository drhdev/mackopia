import Foundation
import Testing

@testable import KopiaServer

@Test func nativeSourceDTOReadsRecordedIdleAndActiveProgress() throws {
    let decoder = JSONDecoder()
    let sources = try decoder.decode(KopiaSources.self, from: fixture("rest-sources"))
    #expect(sources.localUsername == "test-user")
    let idle = try #require(sources.sources?.first)
    #expect(idle.source?.path == "/fixture/source")
    #expect(idle.source?.userName == "test-user")
    #expect(idle.source?.host == "test-host")
    #expect(idle.status == "IDLE")
    #expect(idle.upload == nil)
    #expect(idle.lastSnapshot?.stats?.totalSize == 22)
    let active = try decoder.decode(KopiaSourceStatus.self, from: fixture("cancel-active-source"))
    #expect(active.status == "UPLOADING")
    #expect(active.upload?.hashedBytes == 71_303_168)
    #expect(active.upload?.estimatedBytes == 268_435_456)
    #expect(active.upload?.hashedFiles == 32)
    #expect(active.upload?.uploadedBytes == 0)
    #expect(active.currentTask == "2")
    let cancelled = try decoder.decode(KopiaSourceStatus.self, from: fixture("cancel-idle-source"))
    #expect(cancelled.upload == nil)
    #expect(cancelled.lastSnapshot?.incomplete == "canceled")
}

@Test func nativeTaskDTOReadsRecordedCountersAndNullValues() throws {
    let decoder = JSONDecoder()
    let list = try decoder.decode(KopiaTasks.self, from: fixture("rest-tasks"))
    let tasks = try #require(list.tasks)
    #expect(tasks.count == 4)
    let restore = try #require(tasks.first { $0.kind == "Restore" })
    #expect(restore.status == "SUCCESS")
    #expect(restore.counters?["Restored Bytes"]?.value == 30)
    #expect(restore.counters?["Restored Bytes"]?.units == "bytes")
    let open = try #require(tasks.first { $0.kind == "Repository" })
    #expect(open.counters == nil)
    let estimate = try decoder.decode(KopiaTask.self, from: fixture("rest-estimate-finished"))
    #expect(estimate.id == "3")
    #expect(estimate.counters?["Files"]?.value == 2)
    #expect(estimate.counters?["Errors"]?.level == "error")
}

@Test func nativeDTOsPreserveUnknownAndMissingStates() throws {
    let decoder = JSONDecoder()
    let source = try decoder.decode(
        KopiaSourceStatus.self,
        from: Data(#"{"status":"FUTURE_STATE","futureField":42,"upload":{"hashedBytes":5000000000}}"#.utf8))
    #expect(source.status == "FUTURE_STATE")
    #expect(source.source == nil)
    #expect(source.lastSnapshot == nil)
    #expect(source.upload?.hashedBytes == 5_000_000_000)
    #expect(source.upload?.estimatedBytes == nil)
    #expect(source.upload?.errors == nil)
    let task = try decoder.decode(
        KopiaTask.self, from: Data(#"{"status":"FUTURE_STATE","counters":{"New Counter":{"value":5000000000}}}"#.utf8))
    #expect(task.status == "FUTURE_STATE")
    #expect(task.counters?["New Counter"]?.value == 5_000_000_000)
    #expect(task.counters?["New Counter"]?.units == nil)
    let emptySource = try decoder.decode(KopiaSourceStatus.self, from: Data("{}".utf8))
    let emptyTask = try decoder.decode(KopiaTask.self, from: Data("{}".utf8))
    #expect(emptySource.status == nil)
    #expect(emptyTask.status == nil)
}

@Test func nativeDTOsRejectMalformedKnownFieldsAndRedactPrivateValues() throws {
    let decoder = JSONDecoder()
    #expect(throws: DecodingError.self) {
        try decoder.decode(KopiaSourceStatus.self, from: Data(#"{"upload":{"hashedBytes":"broken"}}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try decoder.decode(KopiaTasks.self, from: Data(#"{"tasks":{}}"#.utf8))
    }
    let sources = try decoder.decode(KopiaSources.self, from: fixture("rest-sources"))
    let source = try #require(sources.sources?.first)
    #expect(!String(reflecting: sources).contains("test-user"))
    #expect(!String(reflecting: source).contains("/fixture/source"))
    #expect(!String(reflecting: source.source).contains("test-host"))
    let tasks = try decoder.decode(KopiaTasks.self, from: fixture("rest-tasks"))
    #expect(!String(reflecting: tasks).contains("/fixture/restored"))
}
