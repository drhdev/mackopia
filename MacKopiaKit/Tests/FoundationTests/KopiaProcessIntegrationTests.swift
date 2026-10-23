import Darwin
import Foundation
import Testing

@testable import KopiaCLI

extension Tag {
    @Tag static var integration: Self
}

private enum NativeKopiaFixture {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    struct Pin: Decodable { let version: String }
    static let pin = (try? Data(contentsOf: root.appendingPathComponent("Config/kopia-version.json")))
        .flatMap { try? JSONDecoder().decode(Pin.self, from: $0) }
    static let binary = root.appendingPathComponent("Vendor/kopia/" + (pin?.version ?? "invalid-pin") + "/kopia")
}

@Suite(
    "Real pinned Kopia command execution", .tags(.integration),
    .enabled(
        if: FileManager.default.isExecutableFile(atPath: NativeKopiaFixture.binary.path)
            || ProcessInfo.processInfo.environment["MACKOPIA_REQUIRE_KOPIA_INTEGRATION"] == "1"))
struct KopiaProcessIntegrationTests {
    @Test func versionMatchesRepositoryPin() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let pin = try #require(NativeKopiaFixture.pin)
        let environment = KopiaProcessTests().request(root, script: "").environment
        let result = try await KopiaProcess().run(
            KopiaProcessRequest(
                executable: NativeKopiaFixture.binary,
                arguments: ["--version"], environment: environment))
        #expect(result.exitCode == 0)
        let version = try #require(String(decoding: result.standardOutput, as: UTF8.self).split(separator: " ").first)
        #expect(String(version) == pin.version)
    }

    @Test func createThenReadStatusAndOwnerThroughNativeRunner() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        let state = paths.configurationDirectory
        try FileManager.default.createDirectory(
            at: state, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let context = KopiaExecutionContext(
            executable: NativeKopiaFixture.binary, paths: paths,
            temporaryDirectory: root, user: "test-user", configuration: .file, backupPassword: UUID().uuidString)
        let process = KopiaProcess()
        let statusRequest = context.request(for: .repositoryStatus)
        // Only this integration test constructs a create invocation, against a brand-new temp path.
        let create = KopiaProcessRequest(
            executable: NativeKopiaFixture.binary,
            arguments: [
                "--config-file=" + state.appendingPathComponent("repository.config").path,
                "--log-dir=" + paths.logDirectory.path, "--no-progress", "--no-use-keychain",
                "--no-persist-credentials",
                "repository", "create", "filesystem", "--path=" + root.appendingPathComponent("storage").path,
                "--cache-directory=" + paths.cacheDirectory.path,
                "--override-username=test-user", "--override-hostname=test-host", "--no-check-for-updates",
            ],
            environment: statusRequest.environment)
        #expect(try await process.run(create).exitCode == 0)
        let commands = KopiaCommandRunner(process: process)
        let status = try await commands.run(.repositoryStatus, context: context)
        let object = try #require(JSONSerialization.jsonObject(with: status) as? [String: Any])
        #expect(object["configFile"] as? String == state.appendingPathComponent("repository.config").path)
        let maintenance = try await commands.run(.maintenanceInfo, context: context)
        let owner = try #require(JSONSerialization.jsonObject(with: maintenance) as? [String: Any])
        #expect(owner["owner"] as? String == "test-user@test-host")
        let config = try Data(contentsOf: state.appendingPathComponent("repository.config"))
        #expect(config.range(of: Data(context.backupPassword.utf8)) == nil)
    }
    @Test func webDAVCreateAndReconnectThroughNativePipe() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let password = UUID().uuidString
        let user = UUID().uuidString
        let fixture = Process()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        fixture.arguments = [
            NativeKopiaFixture.root.appendingPathComponent("Scripts/native_webdav_fixture.py").path,
            root.appendingPathComponent("storage").path,
        ]
        fixture.environment = [
            "HOME": root.path, "TMPDIR": root.path, "LANG": "en_US.UTF-8",
            "PYTHONDONTWRITEBYTECODE": "1", "FIXTURE_USER": user, "FIXTURE_PASSWORD": password,
        ]
        let control = Pipe()
        let readiness = Pipe()
        fixture.standardInput = control
        fixture.standardOutput = readiness
        fixture.standardError = FileHandle.nullDevice
        try fixture.run()
        defer {
            try? control.fileHandleForWriting.close()
            if fixture.isRunning { fixture.terminate() }
            fixture.waitUntilExit()
        }
        let descriptor = readiness.fileHandleForReading.fileDescriptor
        #expect(fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !response.contains(10), ContinuousClock.now < deadline {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { response.append(contentsOf: buffer.prefix(count)) }
            if count == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let readinessJSON = try #require(JSONSerialization.jsonObject(with: response) as? [String: Int])
        let port = try #require(readinessJSON["port"])
        let endpoint = "http://127.0.0.1:\(port)"
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        try FileManager.default.createDirectory(
            at: paths.configurationDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // Kopia 0.23.1: complete cache defaults are required when composing runtime config.
        let configuration = try JSONSerialization.data(withJSONObject: [
            "storage": ["type": "webdav", "config": ["url": endpoint, "username": user, "password": password]],
            "caching": [
                "cacheDirectory": paths.cacheDirectory.path, "maxCacheSize": 5_242_880_000,
                "maxMetadataCacheSize": 5_242_880_000, "maxListCacheDuration": 30,
            ],
            "username": "test-user", "hostname": "test-host", "enableActions": false,
        ])
        let context = KopiaExecutionContext(
            executable: NativeKopiaFixture.binary, paths: paths,
            temporaryDirectory: root, user: "test-user", configuration: .webDAV(configuration),
            backupPassword: UUID().uuidString)
        let process = KopiaProcess()
        var environment = context.request(for: .repositoryStatus).environment
        environment["KOPIA_WEBDAV_USERNAME"] = user
        environment["KOPIA_WEBDAV_PASSWORD"] = password
        let create = KopiaProcessRequest(
            executable: NativeKopiaFixture.binary,
            arguments: [
                "--config-file=" + paths.configurationDirectory.appendingPathComponent("repository.config").path,
                "--log-dir=" + paths.logDirectory.path, "--no-use-keychain", "--no-persist-credentials",
                "--no-progress",
                "repository", "create", "webdav", "--create-only", "--url=" + endpoint,
                "--cache-directory=" + paths.cacheDirectory.path, "--no-check-for-updates",
                "--override-username=test-user", "--override-hostname=test-host",
            ], environment: environment)
        #expect(try await process.run(create).exitCode == 0)
        let commands = KopiaCommandRunner(process: process)
        for _ in 0..<2 {
            let status = try await commands.run(.repositoryStatus, context: context)
            let object = try #require(JSONSerialization.jsonObject(with: status) as? [String: Any])
            let storage = try #require(object["storage"] as? [String: Any])
            #expect(storage["type"] as? String == "webdav")
            let containsCredential = [password, context.backupPassword].contains {
                status.range(of: Data($0.utf8)) != nil
            }
            #expect(!containsCredential)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: paths.configurationDirectory.path)
        #expect(entries == ["repository.mlock"])
        try assertNoCredentials(root: root, values: [password, context.backupPassword])
    }

    private func assertNoCredentials(root: URL, values: [String]) throws {
        let files = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let data = try Data(contentsOf: file)
                let containsCredential = values.contains { data.range(of: Data($0.utf8)) != nil }
                #expect(!containsCredential)
            }
        }
    }

}
