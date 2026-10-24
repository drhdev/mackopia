import Darwin
import Foundation
import Testing

@testable import KopiaCLI
@testable import KopiaServer

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
    @Test func controlShutdownStopsRealServerWithoutClosingInput() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = KopiaServerProcess()
        let configuration = try KopiaServerConfiguration(
            executable: NativeKopiaFixture.binary, repositoryID: UUID(), homeDirectory: root,
            temporaryDirectory: root, user: "test-user", backupPassword: UUID().uuidString)
        let handshake = try await server.start(configuration: configuration)
        let client = KopiaServerClient(handshake: handshake)
        do {
            try await client.shutdownServer()
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while await server.isRunning, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await server.isRunning == false)
        } catch {
            await client.close()
            try? await server.stop()
            throw error
        }
        await client.close()
        try await server.stop()
    }

    @Test func parsesRealServerHandshakeAndStopsOnInputEOF() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = KopiaServerProcess()
        let configuration = try KopiaServerConfiguration(
            executable: NativeKopiaFixture.binary, repositoryID: UUID(), homeDirectory: root,
            temporaryDirectory: root, user: "test-user", backupPassword: UUID().uuidString)
        let handshake = try await server.start(configuration: configuration)
        #expect(handshake.address.host == "127.0.0.1")
        #expect(handshake.fingerprint.count == 32)
        let client = KopiaServerClient(handshake: handshake)
        do {
            async let first = client.repositoryStatus()
            async let second = client.repositoryStatus()
            let statuses = try await [first, second]
            #expect(statuses.allSatisfy { $0.connected == false })
            var wrongParser = KopiaServerHandshakeParser()
            let parsed = try wrongParser.consume(
                KopiaServerHandshakeTests().transcript(address: handshake.address.absoluteString))
            let wrongHandshake = try #require(parsed)
            let rejectedClient = KopiaServerClient(handshake: wrongHandshake)
            await #expect(throws: KopiaServerClientError.transport) { try await rejectedClient.repositoryStatus() }
            await rejectedClient.close()
            await client.close()
            await #expect(throws: KopiaServerClientError.closed) { try await client.repositoryStatus() }
        } catch {
            await client.close()
            try? await server.stop()
            throw error
        }
        try await server.stop()
        try await server.stop()

    }

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
        let paths = try KopiaRepositoryPaths(repositoryID: UUID(), homeDirectory: root)
        let verifier = try KopiaBinaryVerifier(
            executable: NativeKopiaFixture.binary, paths: paths, temporaryDirectory: root, expectedVersion: pin.version)
        try await verifier.verify()
        let mismatch = try KopiaBinaryVerifier(
            executable: NativeKopiaFixture.binary, paths: paths, temporaryDirectory: root, expectedVersion: "0.0.0")
        await #expect(throws: KopiaBinaryVerificationError.versionMismatch) { try await mismatch.verify() }
        #expect(!FileManager.default.fileExists(atPath: paths.configurationDirectory.path))
    }

    @Test func createThenReadStatusAndOwnerThroughNativeRunner() async throws {
        let root = try KopiaProcessTests().temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repositoryID = UUID()
        let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: root)
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
        let source = root.appendingPathComponent("Quelle ü + & ? # %2F")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("native source fixture".utf8).write(to: source.appendingPathComponent("hello.txt"))
        let policyRequest = KopiaProcessRequest(
            executable: NativeKopiaFixture.binary,
            arguments: Array(statusRequest.arguments.dropLast(3)) + [
                "policy", "set", source.path, "--keep-latest=10", "--keep-annual=0", "--add-ignore=*.tmp",
                "--compression=zstd",
            ], environment: statusRequest.environment)
        #expect(try await process.run(policyRequest).exitCode == 0)
        let snapshotRequest = KopiaProcessRequest(
            executable: NativeKopiaFixture.binary,
            arguments: Array(statusRequest.arguments.dropLast(3)) + ["snapshot", "create", source.path, "--json"],
            environment: statusRequest.environment)
        #expect(try await process.run(snapshotRequest).exitCode == 0)
        let server = KopiaServerProcess()
        let serverConfiguration = try KopiaServerConfiguration(
            executable: NativeKopiaFixture.binary, repositoryID: repositoryID, homeDirectory: root,
            temporaryDirectory: root, user: "test-user", backupPassword: context.backupPassword)
        let handshake = try await server.start(configuration: serverConfiguration)
        let client = KopiaServerClient(handshake: handshake)
        do {
            let serverStatus = try await client.repositoryStatus()
            #expect(serverStatus.connected == true)
            #expect(serverStatus.storage == "filesystem")
            async let readSources = client.sources()
            async let readTasks = client.tasks()
            let (sources, tasks) = try await (readSources, readTasks)
            #expect(sources.localUsername == "test-user")
            #expect(sources.localHost == "test-host")
            let listedSource = try #require(sources.sources?.first { $0.source?.path == source.path })
            #expect(listedSource.status == "IDLE")
            #expect(listedSource.lastSnapshot?.stats?.totalSize == 21)
            #expect(listedSource.lastSnapshot?.incomplete == nil)
            let selector = try KopiaSnapshotSource(userName: "test-user", host: "test-host", path: source.path)
            let definedPolicy = try #require(try await client.policy(source: selector))
            #expect(definedPolicy.retention?.keepLatest == 10)
            #expect(definedPolicy.retention?.keepAnnual == 0)
            #expect(definedPolicy.files?.ignore == ["*.tmp"])
            let complete = try #require(try await client.policyDefinition(source: selector))
            #expect(complete.source == selector)
            let completeProjection = try JSONDecoder().decode(KopiaPolicy.self, from: complete.document.encoded())
            #expect(completeProjection.retention?.keepLatest == 10)
            #expect(completeProjection.retention?.keepAnnual == 0)
            #expect(completeProjection.files?.ignore == ["*.tmp"])
            #expect(completeProjection.compression?.compressorName == "zstd")
            let resolvedPolicy = try await client.resolvePolicy(source: selector)
            #expect(resolvedPolicy.defined?.retention?.keepDaily == nil)
            #expect(resolvedPolicy.effective?.retention?.keepDaily != nil)
            #expect(resolvedPolicy.effective?.retention?.keepAnnual == 0)
            #expect(resolvedPolicy.effective?.compression?.compressorName == "zstd")
            #expect(resolvedPolicy.definition?.files?["ignore"]?.path == source.path)
            let childSelector = try KopiaSnapshotSource(
                userName: "test-user", host: "test-host", path: source.path + "/child")
            #expect(try await client.policy(source: childSelector) == nil)
            #expect(try await client.policyDefinition(source: childSelector) == nil)
            let snapshotList = try await client.snapshots(source: selector)
            let snapshot = try #require(snapshotList.snapshots?.first)
            #expect(snapshotList.snapshots?.count == 1)
            #expect(snapshot.summary?.size == 21)
            let rootID = try #require(snapshot.rootID)
            let directory = try await client.directory(id: rootID)
            let entry = try #require(directory.entries?.first)
            #expect(directory.entries?.count == 1)
            #expect(entry.name == "hello.txt")
            #expect(entry.type == "f")
            #expect(entry.size == 21)
            let fileID = try #require(entry.obj)
            await #expect(throws: KopiaServerClientError.response) { try await client.directory(id: fileID) }
            let opening = try #require(tasks.tasks?.first { $0.kind == "Repository" })
            let taskID = try #require(opening.id)
            let detail = try await client.task(id: taskID)
            #expect(detail.id == taskID)
            #expect(detail.kind == "Repository")
            #expect(detail.status == "SUCCESS")

        } catch {
            await client.close()
            try? await server.stop()
            throw error
        }
        await client.close()
        try await server.stop()
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
        let repositoryID = UUID()
        let paths = try KopiaRepositoryPaths(repositoryID: repositoryID, homeDirectory: root)
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
        for _ in 0..<2 {
            let server = KopiaServerProcess()
            let serverConfiguration = try KopiaServerConfiguration(
                executable: NativeKopiaFixture.binary, repositoryID: repositoryID, homeDirectory: root,
                temporaryDirectory: root, user: "test-user", backupPassword: context.backupPassword,
                configuration: .webDAV(configuration))
            let handshake = try await server.start(configuration: serverConfiguration)
            let client = KopiaServerClient(handshake: handshake)
            do {
                let status = try await client.repositoryStatus()
                #expect(status.connected == true)
                #expect(status.storage == "webdav")
            } catch {
                await client.close()
                try? await server.stop()
                throw error
            }
            await client.close()
            try await server.stop()
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
