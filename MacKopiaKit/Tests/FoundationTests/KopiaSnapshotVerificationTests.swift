import Foundation
import Testing

@testable import KopiaCLI

struct KopiaSnapshotVerificationTests {
    @Test func targetsMustBeExactNonemptyManifestIDs() {
        for ids in [
            [], ["--all-sources"], ["/private/path"], ["a"], [String(repeating: "A", count: 32)],
            Array(repeating: String(repeating: "1", count: 32), count: 2),
        ] {
            #expect(throws: KopiaProcessError.invalidRequest) {
                try KopiaSnapshotVerification(snapshotIDs: ids, filesPercent: 1)
            }
        }
        for percent in [0, 101, Int.max] {
            #expect(throws: KopiaProcessError.invalidRequest) {
                try KopiaSnapshotVerification(snapshotIDs: [String(repeating: "a", count: 32)], filesPercent: percent)
            }
        }
    }

    @Test func boundedBatchesUseIsolatedStateAndEnvironmentOnlySecret() async throws {
        let process = VerifyProcessFixture()
        let ids = (0..<130).map { String(format: "%032x", $0) }
        try await execute(process, ids: ids)
        let requests = await process.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.lowPriority && $0.timeout == .seconds(6 * 60 * 60) })
        #expect(requests.allSatisfy { $0.arguments.contains("--verify-files-percent=10") })
        #expect(requests.allSatisfy { $0.arguments.contains("--json") })
        #expect(requests.flatMap(\.arguments).filter { ids.contains($0) } == ids)
        for request in requests {
            #expect(request.environment["KOPIA_PASSWORD"] == "private-test-marker")
            #expect(!request.arguments.contains { $0.contains("private-test-marker") })
            #expect(request.arguments.contains { $0.hasPrefix("--config-file=/tmp/verify-home/Library/") })
            #expect(request.arguments.contains { $0.hasPrefix("--log-dir=/tmp/verify-home/Library/") })
            #expect(request.environment["KOPIA_CACHE_DIRECTORY"]?.hasPrefix("/tmp/verify-home/Library/") == true)
        }
    }

    @Test func exitErrorsMalformedEmptyAndReportedFailuresAreRejected() async throws {
        for (code, output) in [
            (Int32(1), "private-marker"), (0, "not-json"), (0, "{}"),
            (0, #"{"stats":{"processedObjectCount":0},"errorCount":0}"#),
            (0, #"{"stats":{"processedObjectCount":2},"errorCount":1}"#),
            (0, #"{"stats":{"processedObjectCount":-1},"errorCount":0}"#),
        ] {
            let process = VerifyProcessFixture(code: code, output: output)
            await #expect(throws: (any Error).self) { try await execute(process) }
        }
    }

    private func execute(
        _ process: VerifyProcessFixture, ids: [String] = [String(repeating: "a", count: 32)]
    ) async throws {
        try await KopiaSnapshotVerifier(process: process).verify(
            KopiaSnapshotVerification(snapshotIDs: ids, filesPercent: 10),
            executable: URL(fileURLWithPath: "/tmp/test-kopia"),
            paths: KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/tmp/verify-home")),
            temporaryDirectory: URL(fileURLWithPath: "/tmp"), user: "test-user",
            backupPassword: "private-test-marker", lowPriority: true)
    }
}

actor VerifyProcessFixture: KopiaProcessRunning {
    var requests: [KopiaProcessRequest] = []
    let code: Int32
    let output: String

    init(code: Int32 = 0, output: String = #"{"stats":{"processedObjectCount":2},"errorCount":0}"#) {
        self.code = code
        self.output = output
    }

    func run(_ request: KopiaProcessRequest) async throws -> KopiaProcessResult {
        requests.append(request)
        return KopiaProcessResult(exitCode: code, standardOutput: Data(output.utf8), standardError: Data())
    }
}
