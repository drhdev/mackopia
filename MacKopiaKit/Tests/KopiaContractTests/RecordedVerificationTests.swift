import Foundation
import Testing

@testable import KopiaCLI

@Test func recordedSnapshotVerifyHasAggregateWorkAndNoErrors() throws {
    let result = try JSONDecoder().decode(
        KopiaSnapshotVerifier.Response.self, from: fixture("cli-snapshot-verify"))
    #expect(result.errorCount == 0)
    #expect(result.stats.processedObjectCount == 4)
}
