import Foundation
import Testing

@testable import KopiaServer

@Test func recordedPinReplacesOnlyManifestAndPreservesExistingProtection() throws {
    struct Record: Decodable {
        let before: KopiaSnapshot
        let response: [KopiaSnapshot]
        let after: [KopiaSnapshot]
    }
    let record = try JSONDecoder().decode(Record.self, from: fixture("rest-snapshot-pin"))
    #expect(record.response.count == 1)
    let pinned = try #require(record.response.first)
    #expect(pinned.id != record.before.id)
    #expect(pinned.rootID == record.before.rootID)
    #expect(pinned.startTime == record.before.startTime)
    #expect(pinned.endTime == record.before.endTime)
    #expect(pinned.summary?.size == record.before.summary?.size)
    #expect(pinned.summary?.files == record.before.summary?.files)
    #expect(Set(pinned.pins ?? []) == ["fixture-existing", KopiaServerClient.plausibilityPin])
    #expect(record.after.contains { $0.id == pinned.id })
    #expect(!record.after.contains { $0.id == record.before.id })
}
