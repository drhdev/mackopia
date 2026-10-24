import Darwin
import Foundation
import Testing

@testable import KopiaCLI

@Suite("Finite child process lifecycle")
struct KopiaProcessTests {
    func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mackopia-runner-\(UUID())")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    func request(_ root: URL, script: String, arguments: [String] = []) -> KopiaProcessRequest {
        KopiaProcessRequest(
            executable: TestPythonRuntime.executable, arguments: ["-c", script] + arguments,
            environment: [
                "HOME": root.path, "USER": "test-user", "TMPDIR": root.path,
                "KOPIA_CACHE_DIRECTORY": root.appendingPathComponent("cache").path,
                "KOPIA_LOG_DIR": root.appendingPathComponent("logs").path,
            ])
    }

    @Test func lowPriorityIsAppliedAtSpawn() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var invocation = request(
            root,
            script:
                "import ctypes,sys; lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib'); sys.stdout.write(str(lib.qos_class_self()))"
        )
        invocation.lowPriority = true
        let result = try await KopiaProcess().run(invocation)
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == String(QOS_CLASS_BACKGROUND.rawValue))
    }

    @Test func drainsBothPipesBeyondKernelCapacity() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await KopiaProcess().run(
            request(root, script: "import os\nfor _ in range(128):\n os.write(1,b'O'*8192)\n os.write(2,b'E'*8192)"))
        #expect(result.exitCode == 0)
        #expect(result.standardOutput == Data(repeating: 79, count: 1_048_576))
        #expect(result.standardError == Data(repeating: 69, count: 1_048_576))
    }

    @Test func isolatedEnvironmentAndLiteralArguments() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let literal = "folder ; $(touch forbidden) ' quote"
        let result = try await KopiaProcess().run(
            request(
                root,
                script:
                    "import os,json,sys; assert sys.stdin.buffer.read()==b''; assert 'PATH' not in os.environ; assert 'SSH_AUTH_SOCK' not in os.environ; assert os.environ['LC_ALL']=='en_US.UTF-8'; assert os.environ['KOPIA_CHECK_FOR_UPDATES']=='false'; sys.stdout.write(sys.argv[1])",
                arguments: [literal]))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.standardOutput, as: UTF8.self) == literal)
    }

    @Test func capturesNonzeroExitWithoutExposingItInDiagnostics() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = UUID().uuidString
        var invocation = request(
            root, script: "import os,sys; sys.stderr.write(os.environ['KOPIA_PASSWORD']); sys.exit(23)")
        invocation.environment["KOPIA_PASSWORD"] = secret
        let result = try await KopiaProcess().run(invocation)
        #expect(result.exitCode == 23)
        #expect(result.standardError == Data(secret.utf8))
        #expect(!String(reflecting: invocation).contains(secret))
        #expect(!String(reflecting: result).contains(secret))
    }

    @Test func pipeDeliveryAndEarlyChildExitDoNotHang() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repository-state")
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var invocation = request(
            root,
            script:
                "import pathlib,sys; p=sys.argv[1].split('=',1)[1]; d=pathlib.Path(p).read_bytes(); assert len(d)==65536; assert all(c==65 for c in d)"
        )
        invocation.webDAVConfiguration = Data(repeating: 65, count: 65_536)
        invocation.repositoryDirectory = repository
        let result = try await KopiaProcess().run(invocation)
        #expect(result.exitCode == 0)
        invocation = request(root, script: "import sys; sys.exit(17)")
        invocation.webDAVConfiguration = Data(repeating: 65, count: 65_536)
        invocation.repositoryDirectory = repository
        #expect(try await KopiaProcess().run(invocation).exitCode == 17)
        let entries = try FileManager.default.contentsOfDirectory(atPath: repository.path)
        #expect(entries == ["repository.mlock"])
    }

    @Test func invalidRequestAndFailedSpawnCleanUp() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var invocation = request(root, script: "pass")
        invocation.environment["DYLD_INSERT_LIBRARIES"] = "/must-not-be-loaded"
        await #expect(throws: KopiaProcessError.invalidRequest) { try await KopiaProcess().run(invocation) }
        invocation = KopiaProcessRequest(
            executable: root.appendingPathComponent("missing"), arguments: [],
            environment: request(root, script: "").environment)
        invocation.webDAVConfiguration = Data(repeating: 65, count: 65_536)
        invocation.repositoryDirectory = root
        await #expect(throws: KopiaProcessError.launchFailed) { try await KopiaProcess().run(invocation) }
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(entries == ["repository.mlock"])
    }

    @Test func outputLimitStopsAndReapsChild() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var invocation = request(root, script: "import os\nwhile True: os.write(1,b'X'*32768)")
        invocation.outputLimit = 65_536
        let runner = KopiaProcess(interruptGrace: .milliseconds(40), terminateGrace: .milliseconds(40))
        await #expect(throws: KopiaProcessError.outputLimitExceeded) { try await runner.run(invocation) }
    }

    @Test func deadlineEscalatesAndReapsUncooperativeChild() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("ready")
        let script = """
            import os,signal,time,pathlib,sys
            p=pathlib.Path(sys.argv[1])
            signal.signal(signal.SIGINT,lambda *_: p.with_suffix('.signals').open('a').write('I'))
            signal.signal(signal.SIGTERM,lambda *_: p.with_suffix('.signals').open('a').write('T'))
            p.write_text(str(os.getpid()))
            while True: time.sleep(1)
            """
        var invocation = request(root, script: script, arguments: [marker.path])
        invocation.timeout = .seconds(2)
        let runner = KopiaProcess(interruptGrace: .milliseconds(40), terminateGrace: .milliseconds(40))
        await #expect(throws: KopiaProcessError.timedOut) { try await runner.run(invocation) }
        #expect(
            try String(contentsOf: marker.deletingPathExtension().appendingPathExtension("signals"), encoding: .utf8)
                == "IT")
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    @Test func cancellationWaitsForReaping() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("ready")
        let invocation = request(
            root,
            script:
                "import os,time,pathlib,sys,signal; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)",
            arguments: [marker.path])
        let runner = KopiaProcess(interruptGrace: .milliseconds(40), terminateGrace: .milliseconds(40))
        let task = Task { try await runner.run(invocation) }
        defer { task.cancel() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8)))
        #expect(kill(pid, 0) == -1)
        #expect(errno == ESRCH)
    }
    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = request(
            root, script: "import pathlib,sys; pathlib.Path(sys.argv[1]).touch()",
            arguments: [root.appendingPathComponent("must-not-exist").path])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await KopiaProcess().run(invocation)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func leaderExitStopsRemainingGroupMembers() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let heartbeat = root.appendingPathComponent("heartbeat")
        let script = """
            import os,pathlib,sys,time
            p=pathlib.Path(sys.argv[1])
            child=os.fork()
            if child==0:
                while True:
                    p.write_text(str(time.monotonic_ns()))
                    time.sleep(0.01)
            else:
                while not p.exists(): time.sleep(0.01)
                os._exit(0)
            """
        var invocation = request(root, script: script, arguments: [heartbeat.path])
        invocation.timeout = .seconds(5)
        #expect(try await KopiaProcess().run(invocation).exitCode == 0)
        let previous = try Data(contentsOf: heartbeat)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try Data(contentsOf: heartbeat) == previous)
    }

    @Test func failingClockStillTerminatesAndReapsChild() async throws {
        struct FailingClock: Clock {
            var now: ContinuousClock.Instant { ContinuousClock.now }
            var minimumResolution: Duration { .nanoseconds(1) }
            func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {
                throw CancellationError()
            }
        }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let invocation = request(root, script: "import time; time.sleep(60)")
        await #expect(throws: KopiaProcessError.ioFailed) {
            try await KopiaProcess(clock: FailingClock()).run(invocation)
        }
    }

}
