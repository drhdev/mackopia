import Foundation
import Testing

private struct RESTSnapshotList: Decodable {
    struct Snapshot: Decodable {
        let rootID: String
        let startTime: String
    }

    let snapshots: [Snapshot]
}

private struct RESTRestoreRequest: Decodable {
    struct Output: Decodable {
        let targetPath: String
        let overwriteFiles: Bool
        let overwriteDirectories: Bool
        let overwriteSymlinks: Bool
        let writeFilesAtomically: Bool
    }

    struct Options: Decodable {
        let restoreDirEntryAtDepth: Int32
        let deleteExtra: Bool
        let ignoreErrors: Bool
    }

    let root: String
    let fsOutput: Output
    let options: Options
}

private struct RESTTask: Decodable {
    struct Counter: Decodable {
        let value: Int
    }

    let id: String
    let kind: String
    let status: String
    let counters: [String: Counter]
}

@Test func recordedRESTTasksCompleteWithMatchingData() throws {
    let decoder = JSONDecoder()
    let estimate = try decoder.decode(RESTTask.self, from: fixture("rest-estimate-finished"))
    let restore = try decoder.decode(RESTTask.self, from: fixture("rest-restore-finished"))
    #expect(estimate.kind == "Estimate")
    #expect(restore.kind == "Restore")
    #expect(estimate.status == "SUCCESS")
    #expect(restore.status == "SUCCESS")
    #expect(estimate.counters["Bytes"]?.value == 30)
    #expect(restore.counters["Restored Bytes"]?.value == estimate.counters["Bytes"]?.value)
    #expect(restore.counters["Restored Files"]?.value == 2)
    #expect(restore.counters["Ignored Errors"]?.value == 0)
    let started = try decoder.decode(RESTTask.self, from: fixture("rest-restore-start"))
    #expect(started.id == restore.id)
}

@Test func recordedRestoreTargetsLatestSnapshotWithSafeOptions() throws {
    let decoder = JSONDecoder()
    let request = try decoder.decode(RESTRestoreRequest.self, from: fixture("rest-restore-request"))
    let snapshots = try decoder.decode(RESTSnapshotList.self, from: fixture("rest-snapshots"))
    let newest = try #require(snapshots.snapshots.max { $0.startTime < $1.startTime })
    #expect(snapshots.snapshots.count == 2)
    #expect(request.root == newest.rootID)
    #expect(request.fsOutput.targetPath == "/fixture/restored")
    #expect(!request.fsOutput.overwriteFiles)
    #expect(!request.fsOutput.overwriteDirectories)
    #expect(!request.fsOutput.overwriteSymlinks)
    #expect(request.fsOutput.writeFilesAtomically)
    #expect(request.options.restoreDirEntryAtDepth == .max)
    #expect(!request.options.deleteExtra)
    #expect(!request.options.ignoreErrors)
}
