import BackupDomain
import Foundation
import Testing

@testable import KopiaCLI

struct KopiaMaintenanceTests {
    @Test func exactOwnerAndEnabledCycleControlFullMaintenance() throws {
        let identity = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host")
        let date = try Date.ISO8601FormatStyle().parse("2026-10-25T10:00:00Z")
        #expect(try info().fullMaintenance(identity: identity, at: date) == .due)
        #expect(try info(owner: "").fullMaintenance(identity: identity, at: date) == .ownerRequired)
        #expect(try info(owner: "test-user@other-host").fullMaintenance(identity: identity, at: date) == .foreignOwner)
        #expect(try info(owner: "TEST-USER@test-host").fullMaintenance(identity: identity, at: date) == .foreignOwner)
        #expect(try info(enabled: false).fullMaintenance(identity: identity, at: date) == .disabled)
        let scheduled = try info(next: "2026-10-25T10:00:00.123456789Z")
        let next = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-10-25T10:00:00.123456789Z")
        #expect(try scheduled.fullMaintenance(identity: identity, at: date) == .scheduled(next))
        #expect(try scheduled.fullMaintenance(identity: identity, at: next) == .due)
        #expect(!String(reflecting: scheduled).contains("test-host"))
    }

    @Test func malformedFieldsFailClosedWithoutRawDiagnostics() throws {
        for output in [
            "{}", "private-marker", #"{"owner":"private-marker","full":{},"schedule":{}}"#,
            maintenanceJSON(interval: "0"), maintenanceJSON(interval: "-1"),
            maintenanceJSON(interval: "1.5"), maintenanceJSON(interval: "9223372036854775808"),
            maintenanceJSON(next: "invalid-private-marker"), maintenanceJSON(owner: "bad\\nowner"),
            maintenanceJSON(owner: String(repeating: "x", count: 4097)),
        ] {
            #expect(throws: KopiaProcessError.invalidRequest) { try KopiaMaintenanceInfo(data: Data(output.utf8)) }
        }
        let identity = try SnapshotIdentity(overrideUser: "test-user", overrideHost: "test-host")
        #expect(throws: KopiaProcessError.invalidRequest) {
            try info().fullMaintenance(identity: identity, at: Date(timeIntervalSinceReferenceDate: .infinity))
        }
    }

    @Test func readerUsesOnlyIsolatedReadCommandAndEnvironmentSecret() async throws {
        let process = VerifyProcessFixture(output: maintenanceJSON())
        _ = try await read(process)
        let request = try #require(await process.requests.first)
        #expect(request.arguments.suffix(3) == ["maintenance", "info", "--json"])
        #expect(request.arguments.contains { $0.hasPrefix("--config-file=/tmp/maintenance-home/Library/") })
        #expect(request.arguments.contains { $0.hasPrefix("--log-dir=/tmp/maintenance-home/Library/") })
        #expect(request.environment["KOPIA_CACHE_DIRECTORY"]?.hasPrefix("/tmp/maintenance-home/Library/") == true)
        #expect(request.environment["KOPIA_PASSWORD"] == "private-test-marker")
        #expect(!request.arguments.contains { $0.contains("private-test-marker") })
        #expect(request.timeout == .seconds(120) && request.lowPriority)
        await #expect(throws: KopiaProcessError.commandFailed(exitCode: 7)) {
            try await read(VerifyProcessFixture(code: 7, output: "private-marker"))
        }
        await #expect(throws: KopiaProcessError.invalidRequest) {
            try await read(VerifyProcessFixture(output: "private-marker"))
        }
    }

    private func info(
        owner: String = "test-user@test-host", enabled: Bool = true, next: String = "0001-01-01T00:00:00Z"
    ) throws -> KopiaMaintenanceInfo {
        try KopiaMaintenanceInfo(data: Data(maintenanceJSON(owner: owner, enabled: enabled, next: next).utf8))
    }

    private func read(_ process: VerifyProcessFixture) async throws -> KopiaMaintenanceInfo {
        try await KopiaMaintenanceReader(process: process).read(
            executable: URL(fileURLWithPath: "/tmp/test-kopia"),
            paths: KopiaRepositoryPaths(
                repositoryID: UUID(), homeDirectory: URL(fileURLWithPath: "/tmp/maintenance-home")),
            temporaryDirectory: URL(fileURLWithPath: "/tmp"), user: "test-user",
            backupPassword: "private-test-marker", lowPriority: true)
    }
}

func maintenanceJSON(
    owner: String = "test-user@test-host", enabled: Bool = true,
    next: String = "0001-01-01T00:00:00Z", interval: String = "86400000000000"
) -> String {
    """
    {"owner":"\(owner)","full":{"enabled":\(enabled),"interval":\(interval)},
    "schedule":{"nextFullMaintenance":"\(next)","runs":{"full":[{"error":"private-marker"}]}}}
    """
}
