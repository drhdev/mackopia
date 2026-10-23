import Darwin
import Foundation
import Testing

@testable import KopiaCLI

@Suite("Memory-only Kopia configuration transport")
struct KopiaConfigurationPipeTests {
    private func repositoryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mackopia-pipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    @Test func largePayloadAndEOF() async throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data((0..<KopiaConfigurationPipe.maximumPayloadSize).map { UInt8($0 % 251) })
        let transport = try KopiaConfigurationPipe(payload: payload, repositoryDirectory: root)
        defer { transport.close() }
        let reader = FileHandle(fileDescriptor: transport.readDescriptor, closeOnDealloc: false)
        let received = try reader.readToEnd()
        try await transport.waitForDelivery()
        #expect(received == payload)
        #expect(fcntl(transport.readDescriptor, F_GETFD) & FD_CLOEXEC != 0)
    }

    @Test func protectedPathsAndSharedLock() throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        let second = try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        defer { second.close(); first.close() }
        #expect(first.configurationURL != second.configurationURL)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: first.configurationURL.path) == "/dev/fd/3")
        let directory = first.configurationURL.deletingLastPathComponent()
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o500)
        let forbidden = directory.appendingPathComponent("unexpected.config")
        #expect(open(forbidden.path, O_CREAT | O_WRONLY, 0o600) == -1)

        let lock1 = open(first.configurationURL.path + ".mlock", O_RDWR)
        let lock2 = open(second.configurationURL.path + ".mlock", O_RDWR)
        defer { Darwin.close(lock1); Darwin.close(lock2) }
        #expect(lock1 >= 0 && lock2 >= 0)
        #expect(flock(lock1, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(lock2, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        #expect(flock(lock1, LOCK_UN) == 0)
        #expect(flock(lock2, LOCK_EX | LOCK_NB) == 0)
        first.close()
        second.close()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["repository.mlock"])
    }

    @Test func cancellationWithNoReader() async throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try KopiaConfigurationPipe(
            payload: Data(repeating: 65, count: KopiaConfigurationPipe.maximumPayloadSize),
            repositoryDirectory: root)
        transport.close()
        transport.close()
        do {
            try await transport.waitForDelivery()
            // Delivery may finish before cancellation if the OS buffers the entire payload.
        } catch is CancellationError {
            // Either cancellation or EPIPE can win the race; neither may hang or raise SIGPIPE.
        } catch let error as KopiaConfigurationError {
            #expect(error == .deliveryFailed)
        }
        #expect(transport.readDescriptor == -1)
        #expect(!FileManager.default.fileExists(atPath: transport.configurationURL.deletingLastPathComponent().path))
    }

    @Test func rejectsInvalidPayloadAndUnsafeLock() throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for payload in [Data(), Data(repeating: 0, count: KopiaConfigurationPipe.maximumPayloadSize + 1)] {
            #expect(throws: KopiaConfigurationError.invalidPayload) {
                try KopiaConfigurationPipe(payload: payload, repositoryDirectory: root)
            }
        }
        let target = root.appendingPathComponent("unrelated")
        try Data("must remain unchanged".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("repository.mlock"), withDestinationURL: target)
        #expect(throws: KopiaConfigurationError.unsafeDirectory) {
            try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "must remain unchanged")
    }

    @Test func rejectsSharedDirectoryAndInsecureExistingLock() throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(chmod(root.path, 0o755) == 0)
        #expect(throws: KopiaConfigurationError.unsafeDirectory) {
            try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        }
        #expect(chmod(root.path, 0o700) == 0)
        let lock = root.appendingPathComponent("repository.mlock")
        try Data().write(to: lock)
        #expect(chmod(lock.path, 0o644) == 0)
        #expect(throws: KopiaConfigurationError.unsafeDirectory) {
            try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["repository.mlock"])
    }

    @Test func scopeExitCleansUpWithoutExplicitClose() throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory: URL
        do {
            let transport = try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
            directory = transport.configurationURL.deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func descriptorIsExplicitlyInheritedByRealChild() async throws {
        let root = try repositoryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = try KopiaConfigurationPipe(payload: Data("{}".utf8), repositoryDirectory: root)
        defer { transport.close() }
        var actions: posix_spawn_file_actions_t?
        #expect(posix_spawn_file_actions_init(&actions) == 0)
        defer { posix_spawn_file_actions_destroy(&actions) }
        #expect(
            posix_spawn_file_actions_adddup2(&actions, transport.readDescriptor, KopiaConfigurationPipe.childDescriptor)
                == 0)
        #expect(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0)
        // No shell, no secrets in argv/environment, stdin remains an independent descriptor.
        let arguments = [
            "/usr/bin/python3", "-c",
            "import pathlib,sys; assert pathlib.Path(sys.argv[1]).read_bytes() == bytes([123,125]); assert sys.stdin.buffer.read() == bytes()",
            transport.configurationURL.path,
        ]
        let ownedArguments = arguments.map { strdup($0) }
        defer { ownedArguments.forEach { free($0) } }
        var argv = ownedArguments + [nil]
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, arguments[0], &actions, nil, &argv, &environment)
        #expect(result == 0)
        guard result == 0 else { return }
        var status: Int32 = 0
        #expect(waitpid(pid, &status, 0) == pid)
        #expect(status == 0)
        try await transport.waitForDelivery()
    }
}
