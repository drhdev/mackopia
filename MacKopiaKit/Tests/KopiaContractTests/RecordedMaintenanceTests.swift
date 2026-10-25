import BackupDomain
import Foundation
import Testing

@testable import KopiaCLI

@Test func recordedMaintenanceRecognizesGoZeroTimeAndStableOwner() throws {
    let info = try KopiaMaintenanceInfo(data: fixture("maintenance-info"))
    let identity = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host")
    #expect(try info.fullMaintenance(identity: identity, at: Date(timeIntervalSince1970: 0)) == .due)
    let foreign = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "other-host")
    #expect(try info.fullMaintenance(identity: foreign, at: .now) == .foreignOwner)
}
