import BackupDomain
import BackupEngine
import Darwin
import Foundation
import Testing

@testable import SystemIntegration

struct TCPReachabilityTests {
    @Test func realTCPProbeConnectsWithoutApplicationBytesAndClosesTransport() async throws {
        let listener = try ReachabilityListener()
        defer { close(listener.descriptor) }
        let peer = Task.detached { try listener.acceptEmptyConnection() }
        let target = try #require(ReachabilityTarget(host: "127.0.0.1", port: listener.port))
        let result = try await TCPReachabilityChecker().canConnect(to: target)
        #expect(result)
        #expect(try await peer.value)
    }

    @Test func fiveSecondDeadlineCancelsAndJoinsConnectAttempt() async throws {
        let time = SchedulerTestClock()
        let cleanup = ReachabilityCleanup()
        let checker = TCPReachabilityChecker(clock: time) { _ in
            await cleanup.enter()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await cleanup.finish()
                throw error
            }
        }
        let target = try #require(ReachabilityTarget(host: "127.0.0.1", port: 1))
        let checking = Task { try await checker.canConnect(to: target) }
        try await wait {
            let entered = await cleanup.entered
            return time.sleeperCount == 1 && entered
        }
        time.advance(4)
        #expect(await cleanup.finished == false)
        time.advance(1)
        #expect(try await checking.value == false)
        #expect(await cleanup.finished)
        #expect(time.sleeperCount == 0)
    }

    @Test func cancellationJoinsConnectAndTimeoutCleanup() async throws {
        let time = SchedulerTestClock()
        let cleanup = ReachabilityCleanup()
        let checker = TCPReachabilityChecker(clock: time) { _ in
            await cleanup.enter()
            do { try await Task.sleep(for: .seconds(60)) } catch {
                await cleanup.finish()
                throw error
            }
        }
        let target = try #require(ReachabilityTarget(host: "127.0.0.1", port: 1))
        let checking = Task { try await checker.canConnect(to: target) }
        try await wait {
            let entered = await cleanup.entered
            return time.sleeperCount == 1 && entered
        }
        checking.cancel()
        await #expect(throws: CancellationError.self) { try await checking.value }
        #expect(await cleanup.finished)
        #expect(time.sleeperCount == 0)
    }

    @Test func endpointMappingUsesOnlyConfiguredHostsPortsAndNetworkRestrictions() throws {
        let smbURL = try #require(URL(string: "smb://nas.invalid/Backups"))
        let smbVolume = try VolumeIdentity(
            uuid: UUID().uuidString, name: "Network", isRemovable: false, isNetwork: true,
            remountURL: smbURL)
        let cases: [(RepositoryKind, String, UInt16)] = [
            (.webdav(url: try #require(URL(string: "https://backup.invalid/Folder"))), "backup.invalid", 443),
            (.webdav(url: try #require(URL(string: "http://[::1]:8080/Folder"))), "::1", 8080),
            (
                .s3(
                    endpoint: "https://storage.invalid:9443/base", bucket: "test", prefix: "", region: nil,
                    objectLock: false), "storage.invalid", 9443
            ),
            (
                .sftp(
                    host: "sftp.invalid", port: 2222, user: "test", path: "/Backup",
                    knownHostsFingerprint: "SHA256:" + String(repeating: "A", count: 43),
                    auth: .password(secretRef: SecretRef())), "sftp.invalid", 2222
            ),
            (.filesystem(path: "/Mounted", volume: smbVolume), "nas.invalid", 445),
        ]
        let conditions = try RunConditions(
            requiresACPower: false, skipOnExpensiveNetwork: true, skipOnConstrainedNetwork: true)
        for (kind, host, port) in cases {
            let repository = try repository(kind)
            let target = try #require(
                DestinationTriggerMapping.networkTarget(repository: repository, conditions: conditions))
            #expect(target.host == host)
            #expect(target.port == port)
            #expect(target.prohibitExpensivePaths)
            #expect(target.prohibitConstrainedPaths)
            #expect(!String(reflecting: target).contains(host))
        }
        #expect(
            DestinationTriggerMapping.networkTarget(
                repository: try repository(.filesystem(path: "/Local", volume: nil)), conditions: conditions) == nil)
        for host in ["", "with space", "name\u{0}", "user@host", "host/path", "[invalid"] {
            #expect(ReachabilityTarget(host: host, port: 22) == nil)
        }
        for port in [-1, 0, 65536, Int.max] { #expect(ReachabilityTarget(host: "127.0.0.1", port: port) == nil) }
    }

    private func repository(_ kind: RepositoryKind) throws -> Repository {
        try Repository(
            name: "Test", kind: kind, identity: SnapshotIdentity(overrideUser: "test", overrideHost: "test-host"),
            secretRef: SecretRef())
    }

    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: .seconds(5))
        while clock.now < end {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private actor ReachabilityCleanup {
    private(set) var entered = false
    private(set) var finished = false
    func enter() { entered = true }
    func finish() { finished = true }
}

private struct ReachabilityListener: Sendable {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var succeeded = false
        defer { if !succeeded { close(descriptor) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        self.descriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        succeeded = true
    }

    func acceptEmptyConnection() throws -> Bool {
        guard ready(descriptor) else { return false }
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { throw POSIXError(.EIO) }
        defer { close(client) }
        guard ready(client) else { return false }
        var byte: UInt8 = 0
        return read(client, &byte, 1) == 0
    }

    private func ready(_ descriptor: Int32) -> Bool {
        var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&item, 1, 5000) > 0
    }
}
