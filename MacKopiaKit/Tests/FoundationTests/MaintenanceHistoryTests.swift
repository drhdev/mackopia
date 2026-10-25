import BackupDomain
import Foundation
import Persistence
import Testing

struct MaintenanceHistoryTests {
    @Test func evidenceSurvivesReopenAndCannotBeReplacedByDuplicateIdentifier() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("history")
        let history = try HistoryStore(directory: directory)
        let id = UUID()
        let success = MaintenanceResult(repositoryID: id, endedAt: .now, outcome: .succeeded)
        try await history.recordMaintenance(success)
        #expect(try await history.latestMaintenance(repositoryID: UUID()) == nil)
        let failure = MaintenanceResult(
            repositoryID: id, endedAt: success.endedAt.addingTimeInterval(1), outcome: .failed)
        try await history.recordMaintenance(failure)
        let overwrite = MaintenanceResult(
            id: failure.id, repositoryID: id,
            endedAt: failure.endedAt.addingTimeInterval(1), outcome: .succeeded)
        await #expect(throws: ConfigStoreError.storageUnavailable) { try await history.recordMaintenance(overwrite) }
        let reopened = try HistoryStore(directory: directory)
        #expect(try await reopened.latestMaintenance(repositoryID: id, before: failure.endedAt) == failure)
        #expect(try await reopened.recent().isEmpty)
    }

    @Test func oldConfigurationsDefaultToQuietNotifications() throws {
        let bytes = Data(#"{"repositories":[],"plans":[]}"#.utf8)
        let configuration = try JSONDecoder().decode(BackupConfiguration.self, from: bytes)
        #expect(!configuration.notificationsEnabled)
        let enabled = try BackupConfiguration(notificationsEnabled: true)
        #expect(try JSONDecoder().decode(BackupConfiguration.self, from: JSONEncoder().encode(enabled)) == enabled)
    }
}
